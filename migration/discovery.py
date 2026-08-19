#!/usr/bin/env python3
"""Turn discovery data into a migration portfolio.

AWS Application Discovery Service produces two things worth having: an inventory
of what exists, and - the part a CMDB usually cannot give you - observed network
connections between servers. This module consumes both and produces workloads
for the tracker, with waves derived from the dependency graph rather than from
whoever shouted loudest in planning.

The rule this implements is the one the migration plan states and that gets
violated first under delivery pressure: **things that talk to each other move
together**. A wave is a connected component of the dependency graph, not a
convenient batch of servers owned by the same team.

Input contract
--------------
Two tables, however you export them. Column names below are what this module
expects; the mapping from an ADS Athena export lives in ``SERVER_FIELDS`` and
``CONNECTION_FIELDS`` so it can be adjusted in one place when the export schema
differs by ADS version:

  servers.csv      server_id, hostname, os_name, cpu_cores, memory_mb, owner
  connections.csv  source_id, destination_id, destination_port, connection_count

Produce them with either:
  aws discovery list-configurations --configuration-type SERVER
  or an Athena query over the ADS continuous export in S3.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from collections import defaultdict
from dataclasses import asdict, dataclass, field
from pathlib import Path

from app.models import Strategy

# Mapping from export column names to this module's field names. ADS Athena
# exports vary between versions, so keep every rename here rather than scattered
# through the parsing code.
SERVER_FIELDS = {
    "server_id": ("server_id", "configurationid", "configuration_id", "agent_id"),
    "hostname": ("hostname", "host_name", "server.hostname", "name"),
    "os_name": ("os_name", "os.name", "osname", "server.osname"),
    "cpu_cores": ("cpu_cores", "numcores", "num_cores", "server.numcpus"),
    "memory_mb": ("memory_mb", "totalraminmb", "total_ram_mb", "server.totalram"),
    "owner": ("owner", "application", "tag_owner", "business_unit"),
}

CONNECTION_FIELDS = {
    "source_id": ("source_id", "sourceserverid", "source_server_id", "agent_id"),
    "destination_id": ("destination_id", "destinationserverid", "destination_server_id"),
    "destination_port": ("destination_port", "destinationport", "port"),
    "connection_count": ("connection_count", "count", "connections"),
}

# Ports that identify a server as backing something else rather than being a
# leaf. A cluster containing one of these is a data tier and migrates earlier in
# its own wave than the applications on top of it.
DATA_PORTS = frozenset({1433, 1521, 3306, 5432, 6379, 9200, 27017})


class DiscoveryError(ValueError):
    """Raised when discovery input cannot be interpreted."""


@dataclass(frozen=True)
class Server:
    """One discovered server."""

    server_id: str
    hostname: str
    os_name: str = ""
    cpu_cores: int = 0
    memory_mb: int = 0
    owner: str = "unassigned"


@dataclass(frozen=True)
class Connection:
    """An observed network connection between two discovered servers."""

    source_id: str
    destination_id: str
    destination_port: int = 0
    connection_count: int = 1


@dataclass(frozen=True)
class PortfolioEntry:
    """A tracker-ready workload derived from discovery data."""

    name: str
    wave: int
    strategy: str
    owner: str
    cluster_size: int
    has_data_tier: bool


@dataclass
class Cluster:
    """A set of servers that must migrate together."""

    servers: list[Server] = field(default_factory=list)
    data_tier_ids: frozenset[str] = frozenset()

    @property
    def has_data_tier(self) -> bool:
        """True when any member of this cluster is served on a database port."""
        return bool(self.data_tier_ids)

    @property
    def size(self) -> int:
        return len(self.servers)

    @property
    def owners(self) -> set[str]:
        return {server.owner for server in self.servers}


def _pick(row: dict[str, str], candidates: tuple[str, ...]) -> str:
    """Return the first present, non-empty candidate column, case-insensitively."""
    lowered = {key.lower().strip(): value for key, value in row.items()}
    for candidate in candidates:
        value = lowered.get(candidate.lower())
        if value not in (None, ""):
            return str(value).strip()
    return ""


def _to_int(value: str) -> int:
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return 0


def parse_servers(rows: list[dict[str, str]]) -> list[Server]:
    """Build servers from exported rows, skipping any without an identifier."""
    servers: list[Server] = []
    for row in rows:
        server_id = _pick(row, SERVER_FIELDS["server_id"])
        if not server_id:
            continue
        hostname = _pick(row, SERVER_FIELDS["hostname"]) or server_id
        servers.append(
            Server(
                server_id=server_id,
                hostname=hostname,
                os_name=_pick(row, SERVER_FIELDS["os_name"]),
                cpu_cores=_to_int(_pick(row, SERVER_FIELDS["cpu_cores"])),
                memory_mb=_to_int(_pick(row, SERVER_FIELDS["memory_mb"])),
                owner=_pick(row, SERVER_FIELDS["owner"]) or "unassigned",
            )
        )
    return servers


def parse_connections(rows: list[dict[str, str]]) -> list[Connection]:
    """Build connections, discarding self-loops and incomplete rows."""
    connections: list[Connection] = []
    for row in rows:
        source = _pick(row, CONNECTION_FIELDS["source_id"])
        destination = _pick(row, CONNECTION_FIELDS["destination_id"])
        if not source or not destination or source == destination:
            continue
        connections.append(
            Connection(
                source_id=source,
                destination_id=destination,
                destination_port=_to_int(_pick(row, CONNECTION_FIELDS["destination_port"])),
                connection_count=_to_int(_pick(row, CONNECTION_FIELDS["connection_count"])) or 1,
            )
        )
    return connections


def dependency_clusters(servers: list[Server], connections: list[Connection]) -> list[Cluster]:
    """Group servers into connected components of the dependency graph.

    Union-find over observed connections. A server with no observed traffic is
    its own cluster of one, which is a useful signal in itself: it is either
    genuinely standalone or a retirement candidate.

    Connections naming servers absent from the inventory are ignored rather than
    invented - discovery data is routinely incomplete, and inventing a workload
    from a connection record produces a portfolio nobody can reconcile.
    """
    by_id = {server.server_id: server for server in servers}
    parent: dict[str, str] = {server_id: server_id for server_id in by_id}

    def find(node: str) -> str:
        while parent[node] != node:
            parent[node] = parent[parent[node]]
            node = parent[node]
        return node

    def union(a: str, b: str) -> None:
        root_a, root_b = find(a), find(b)
        if root_a != root_b:
            parent[root_b] = root_a

    data_tier_ids: set[str] = set()
    for connection in connections:
        if connection.source_id not in by_id or connection.destination_id not in by_id:
            continue
        union(connection.source_id, connection.destination_id)
        if connection.destination_port in DATA_PORTS:
            data_tier_ids.add(connection.destination_id)

    grouped: dict[str, list[Server]] = defaultdict(list)
    for server_id, server in by_id.items():
        grouped[find(server_id)].append(server)

    clusters = [
        Cluster(
            servers=sorted(members, key=lambda s: s.hostname),
            data_tier_ids=frozenset(s.server_id for s in members if s.server_id in data_tier_ids),
        )
        for members in grouped.values()
    ]
    # Deterministic ordering: small and simple first, then by name so repeated
    # runs over the same export produce the same waves.
    return sorted(clusters, key=lambda c: (c.size, c.servers[0].hostname))


def assign_waves(clusters: list[Cluster], max_per_wave: int = 6) -> dict[str, int]:
    """Assign each server a wave number.

    Two rules, in order:

    1. A cluster is never split. Servers that talk to each other cut over
       together or accept measured latency across the link, and deciding that
       per-server during a cutover window is how outages happen.
    2. Simple clusters go first. Wave 1 is where process problems surface, so it
       should carry the least risk. Clusters with a data tier are held back
       because a database cutover is the expensive kind to get wrong.
    """
    ordered = sorted(clusters, key=lambda c: (c.has_data_tier, c.size))

    waves: dict[str, int] = {}
    wave = 1
    used = 0
    previous_had_data = None
    for cluster in ordered:
        # Rule 2 is a hard boundary, not a preference: the first data-tier
        # cluster starts a new wave even if the current one has room. Packing
        # a database cutover in beside the low-risk wave defeats the reason
        # wave 1 exists.
        crosses_into_data = previous_had_data is False and cluster.has_data_tier

        # A cluster larger than the cap still gets its own wave rather than
        # being split; the cap shapes batching, it does not override rule 1.
        if used and (crosses_into_data or used + cluster.size > max_per_wave):
            wave += 1
            used = 0
        previous_had_data = cluster.has_data_tier
        for server in cluster.servers:
            waves[server.server_id] = wave
        used += cluster.size
    return waves


def suggest_strategy(server: Server, cluster: Cluster, connected: bool) -> Strategy:
    """Propose a starting strategy. A human confirms it; this only saves typing.

    Deliberately conservative. Recommending refactor from inventory data alone
    would be guessing at application architecture from CPU counts.
    """
    if not connected and cluster.size == 1:
        # Nothing talks to it and it talks to nothing. Most estates carry 10-20%
        # of these, and each one confirmed is a workload nobody has to migrate.
        return Strategy.RETIRE
    if server.server_id in cluster.data_tier_ids:
        # This server is what other servers connect to on a database port, so a
        # managed equivalent usually exists. Its neighbours are application
        # servers and get no such inference.
        return Strategy.REPLATFORM
    return Strategy.REHOST


def build_portfolio(
    servers: list[Server],
    connections: list[Connection],
    max_per_wave: int = 6,
) -> list[PortfolioEntry]:
    """Produce tracker-ready workload records from discovery data."""
    clusters = dependency_clusters(servers, connections)
    waves = assign_waves(clusters, max_per_wave=max_per_wave)

    connected_ids: set[str] = set()
    known = {server.server_id for server in servers}
    for connection in connections:
        if connection.source_id in known and connection.destination_id in known:
            connected_ids.add(connection.source_id)
            connected_ids.add(connection.destination_id)

    cluster_of = {server.server_id: cluster for cluster in clusters for server in cluster.servers}

    portfolio: list[PortfolioEntry] = []
    for server in sorted(servers, key=lambda s: (waves.get(s.server_id, 99), s.hostname)):
        cluster = cluster_of[server.server_id]
        strategy = suggest_strategy(server, cluster, server.server_id in connected_ids)
        portfolio.append(
            PortfolioEntry(
                name=server.hostname,
                wave=waves.get(server.server_id, 1),
                strategy=strategy.value,
                owner=server.owner,
                cluster_size=cluster.size,
                has_data_tier=cluster.has_data_tier,
            )
        )
    return portfolio


def read_csv(path: Path) -> list[dict[str, str]]:
    """Read a CSV export into rows."""
    try:
        with path.open(newline="", encoding="utf-8-sig") as handle:
            return list(csv.DictReader(handle))
    except OSError as exc:
        raise DiscoveryError(f"cannot read {path}: {exc}") from exc


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--servers", type=Path, required=True, help="Server inventory CSV")
    parser.add_argument("--connections", type=Path, help="Observed connections CSV")
    parser.add_argument("--max-per-wave", type=int, default=6)
    parser.add_argument("--format", choices=["table", "json"], default="table")
    args = parser.parse_args(argv)

    try:
        servers = parse_servers(read_csv(args.servers))
        connections = parse_connections(read_csv(args.connections)) if args.connections else []
    except DiscoveryError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if not servers:
        print("error: no servers found in the inventory export", file=sys.stderr)
        return 2

    portfolio = build_portfolio(servers, connections, max_per_wave=args.max_per_wave)

    if args.format == "json":
        print(json.dumps([asdict(entry) for entry in portfolio], indent=2))
        return 0

    clusters = dependency_clusters(servers, connections)
    print(f"{len(servers)} servers, {len(connections)} observed connections")
    print(f"{len(clusters)} dependency clusters -> {max(e.wave for e in portfolio)} waves\n")
    print(f"{'WAVE':<6}{'WORKLOAD':<28}{'STRATEGY':<13}{'OWNER':<16}CLUSTER")
    for entry in portfolio:
        marker = " (data tier)" if entry.has_data_tier else ""
        print(
            f"{entry.wave:<6}{entry.name:<28}{entry.strategy:<13}"
            f"{entry.owner:<16}{entry.cluster_size}{marker}"
        )

    retire = [e for e in portfolio if e.strategy == "retire"]
    if retire:
        print(f"\n{len(retire)} retirement candidate(s): no observed traffic in either direction.")
        print("Confirm with owners before acting - a quiet service is not always an unused one.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
