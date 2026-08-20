-- ---------------------------------------------------------------------------
-- Produce discovery.py's two inputs from an AWS Application Discovery Service
-- continuous export, in application_discovery_service_database.
--
-- Column names below are the real ones, taken from the schema AWS publishes in
-- its own predefined queries. They are not a guess, and they are not the
-- camelCase names the ADS *API* returns - the Athena export is snake_case and
-- splits the inventory across tables.
--
-- Note: Application Discovery Service closed to new customers on 7 November
-- 2025. These queries apply to an existing ADS export. AWS Transform is the
-- successor and its export schema differs.
-- ---------------------------------------------------------------------------


-- Servers -------------------------------------------------------------------
-- Inventory is split: os_info_agent carries identity, sys_performance_agent
-- carries the hardware. They join on agent_id.
--
-- os_info_agent is append-only, one row per collection, so take the newest row
-- per agent. Cores and RAM are aggregated with MAX rather than by timestamp:
-- hardware does not change between samples, and it avoids assuming a timestamp
-- column on the performance table.
--
-- There is no owner column anywhere in the agent tables. Ownership lives in
-- Migration Hub application groupings or in your CMDB, and has to be joined in
-- separately - discovery.py defaults it to "unassigned".

WITH latest_os AS (
    SELECT agent_id, host_name, os_name,
           ROW_NUMBER() OVER (PARTITION BY agent_id ORDER BY "timestamp" DESC) AS rn
    FROM os_info_agent
),
hardware AS (
    SELECT agent_id,
           MAX(total_num_cores) AS total_num_cores,
           MAX(total_ram_in_mb) AS total_ram_in_mb
    FROM sys_performance_agent
    GROUP BY agent_id
)
SELECT o.agent_id,
       o.host_name,
       o.os_name,
       h.total_num_cores,
       h.total_ram_in_mb
FROM latest_os o
LEFT JOIN hardware h ON o.agent_id = h.agent_id
WHERE o.rn = 1;


-- Connections ---------------------------------------------------------------
-- This is the part that cannot be exported directly. The connection tables
-- record peers as IP addresses, not as server identifiers: agent_id on those
-- rows is the agent that *observed* the connection, not the source server.
--
-- Resolving both endpoints to servers means joining through
-- network_interface_agent twice, which is the same technique AWS uses in its
-- own hostname_ip_helper view.
--
-- The inner joins deliberately drop connections whose peer has no agent. That
-- matches dependency_clusters(), which ignores connections naming servers
-- absent from the inventory rather than inventing a workload from an edge.
-- Run the "identify servers with or without agents" predefined query first if
-- you want to know how much traffic that discards.
--
-- There is no connection count column either. Each row is one observed
-- connection, so the count is COUNT(*), which AWS aliases as "frequency".

WITH nic AS (
    SELECT DISTINCT agent_id, ip_address
    FROM network_interface_agent
)
SELECT src.agent_id          AS source_agent_id,
       dst.agent_id          AS destination_agent_id,
       c.destination_port,
       COUNT(*)              AS frequency
FROM outbound_connection_agent c
JOIN nic src ON c.source_ip = src.ip_address
JOIN nic dst ON c.destination_ip = dst.ip_address
WHERE c.ip_version = 'IPv4'
  AND src.agent_id <> dst.agent_id
GROUP BY src.agent_id, dst.agent_id, c.destination_port;
