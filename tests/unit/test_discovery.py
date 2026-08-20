"""Unit tests for turning discovery data into a migration portfolio."""

from pathlib import Path

import pytest

from app.models import Strategy
from migration.discovery import (
    Connection,
    Server,
    assign_waves,
    build_portfolio,
    dependency_clusters,
    parse_connections,
    parse_servers,
    read_csv,
)

FIXTURES = Path(__file__).parent.parent / "fixtures"


@pytest.fixture
def servers():
    return parse_servers(read_csv(FIXTURES / "ads-servers.csv"))


@pytest.fixture
def connections():
    return parse_connections(read_csv(FIXTURES / "ads-connections.csv"))


def test_ads_column_names_are_recognised(servers):
    """The export uses configurationId/hostName, not our internal field names."""
    assert len(servers) == 8
    billing = next(s for s in servers if s.hostname == "billing-db-01")
    assert billing.server_id == "d-server-0003"
    assert billing.cpu_cores == 8
    assert billing.memory_mb == 65536
    assert billing.owner == "payments"


def test_rows_without_an_identifier_are_skipped():
    assert parse_servers([{"hostName": "orphan", "osName": "Linux"}]) == []


def test_self_referential_connections_are_discarded():
    rows = [{"sourceServerId": "a", "destinationServerId": "a", "destinationPort": "5432"}]
    assert parse_connections(rows) == []


def test_talking_servers_land_in_one_cluster(servers, connections):
    """The whole point: things that talk to each other move together."""
    clusters = dependency_clusters(servers, connections)
    billing = next(c for c in clusters if any(s.hostname == "billing-db-01" for s in c.servers))
    names = {s.hostname for s in billing.servers}
    assert names == {"billing-web-01", "billing-web-02", "billing-db-01", "jump-host-01"}


def test_a_database_port_marks_the_cluster_as_a_data_tier(servers, connections):
    clusters = dependency_clusters(servers, connections)
    billing = next(c for c in clusters if any(s.hostname == "billing-db-01" for s in c.servers))
    assert billing.has_data_tier


def test_silent_servers_form_their_own_clusters(servers, connections):
    clusters = dependency_clusters(servers, connections)
    singles = {c.servers[0].hostname for c in clusters if c.size == 1}
    assert singles == {"legacy-fax-01", "print-spool-01"}


def test_connections_naming_unknown_servers_are_ignored(servers, connections):
    """d-server-0009 appears in the connection export but not the inventory."""
    clusters = dependency_clusters(servers, connections)
    assert sum(c.size for c in clusters) == len(servers)
    assert all(s.server_id != "d-server-0009" for c in clusters for s in c.servers)


def test_a_cluster_is_never_split_across_waves(servers, connections):
    clusters = dependency_clusters(servers, connections)
    waves = assign_waves(clusters, max_per_wave=2)
    for cluster in clusters:
        assigned = {waves[s.server_id] for s in cluster.servers}
        assert len(assigned) == 1, f"cluster {cluster.owners} was split across waves {assigned}"


def test_a_cluster_larger_than_the_cap_still_stays_together():
    servers = [Server(f"s{i}", f"host-{i}") for i in range(10)]
    connections = [Connection(f"s{i}", f"s{i + 1}") for i in range(9)]
    clusters = dependency_clusters(servers, connections)
    waves = assign_waves(clusters, max_per_wave=3)
    assert len(set(waves.values())) == 1


def test_data_tier_clusters_are_held_back(servers, connections):
    """Wave 1 carries the least risk; a database cutover is the expensive kind."""
    clusters = dependency_clusters(servers, connections)
    waves = assign_waves(clusters)
    data_waves = [waves[s.server_id] for c in clusters if c.has_data_tier for s in c.servers]
    plain_waves = [waves[s.server_id] for c in clusters if not c.has_data_tier for s in c.servers]
    assert min(data_waves) > min(plain_waves)


def test_clustering_is_deterministic(servers, connections):
    """Two runs over the same export must produce the same waves."""
    first = assign_waves(dependency_clusters(servers, connections))
    second = assign_waves(dependency_clusters(list(reversed(servers)), connections))
    assert first == second


def test_silent_servers_are_proposed_for_retirement(servers, connections):
    portfolio = build_portfolio(servers, connections)
    retire = {e.name for e in portfolio if e.strategy == Strategy.RETIRE.value}
    assert retire == {"legacy-fax-01", "print-spool-01"}


def test_servers_in_a_data_cluster_are_proposed_for_replatform(servers, connections):
    portfolio = build_portfolio(servers, connections)
    entry = next(e for e in portfolio if e.name == "billing-db-01")
    assert entry.strategy == Strategy.REPLATFORM.value


def test_portfolio_covers_every_discovered_server(servers, connections):
    portfolio = build_portfolio(servers, connections)
    assert {e.name for e in portfolio} == {s.hostname for s in servers}


def test_portfolio_is_ordered_by_wave(servers, connections):
    waves = [e.wave for e in build_portfolio(servers, connections)]
    assert waves == sorted(waves)


def test_inventory_with_no_connections_still_produces_a_portfolio(servers):
    """A discovery run without the agent yields inventory but no dependencies."""
    portfolio = build_portfolio(servers, [])
    assert len(portfolio) == len(servers)
    assert all(e.strategy == Strategy.RETIRE.value for e in portfolio)


def test_empty_inventory_is_not_a_crash():
    assert build_portfolio([], []) == []


def test_only_the_database_server_is_a_replatform_candidate(servers, connections):
    """A jump host in a data cluster is still just a server to lift and shift."""
    portfolio = {e.name: e.strategy for e in build_portfolio(servers, connections)}
    assert portfolio["billing-db-01"] == Strategy.REPLATFORM.value
    assert portfolio["orders-db-01"] == Strategy.REPLATFORM.value
    assert portfolio["billing-web-01"] == Strategy.REHOST.value
    assert portfolio["jump-host-01"] == Strategy.REHOST.value


# ---------------------------------------------------------------------------
# The real ADS Athena export schema.
#
# The fixtures above use the camelCase names the ADS *API* returns. The
# continuous export to Athena is a different schema: snake_case, inventory
# split across os_info_agent and sys_performance_agent, and connections
# recorded between IP addresses rather than server ids. Column names here are
# the ones AWS publishes in its own predefined queries, and match what
# migration/athena/ads-export.sql emits.
# ---------------------------------------------------------------------------


@pytest.fixture
def athena_servers():
    return parse_servers(read_csv(FIXTURES / "ads-athena-servers.csv"))


@pytest.fixture
def athena_connections():
    return parse_connections(read_csv(FIXTURES / "ads-athena-connections.csv"))


def test_athena_export_hardware_columns_are_mapped(athena_servers):
    """total_num_cores and total_ram_in_mb are the real names, not numCores."""
    by_host = {s.hostname: s for s in athena_servers}
    assert by_host["billing-db-01"].cpu_cores == 8
    assert by_host["billing-db-01"].memory_mb == 65536
    assert not any(s.cpu_cores == 0 for s in athena_servers)
    assert not any(s.memory_mb == 0 for s in athena_servers)


def test_athena_export_has_no_owner_column(athena_servers):
    """Ownership is not in any ADS agent table; it comes from Migration Hub."""
    assert all(s.owner == "unassigned" for s in athena_servers)


def test_frequency_is_the_connection_count(athena_connections):
    """ADS has no count column - the export aggregates with COUNT(*)."""
    assert athena_connections[0].connection_count == 48210
    assert not any(c.connection_count == 1 for c in athena_connections)


def test_agent_id_is_not_treated_as_a_connection_source():
    """agent_id on a connection row is the observer, not the source server.

    Accepting it would attribute every connection a host reported to that host.
    Both endpoints are IPs in the raw tables and must be resolved by joining
    network_interface_agent, which ads-export.sql does.
    """
    rows = [{"agent_id": "o-observer", "destination_ip": "10.0.0.9", "destination_port": "5432"}]
    assert parse_connections(rows) == []


def test_athena_export_produces_the_same_shape_of_portfolio(athena_servers, athena_connections):
    portfolio = build_portfolio(athena_servers, athena_connections)
    assert len(portfolio) == len(athena_servers)
    by_name = {e.name: e for e in portfolio}
    assert by_name["billing-db-01"].strategy == Strategy.REPLATFORM.value
    assert by_name["legacy-fax-01"].strategy == Strategy.RETIRE.value
    assert by_name["billing-web-01"].wave > by_name["legacy-fax-01"].wave
