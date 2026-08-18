"""End-to-end HTTP tests against the app backed by real Postgres."""

import pytest

pytestmark = pytest.mark.integration

WORKLOAD = {"name": "billing-api", "wave": 1, "strategy": "replatform", "owner": "platform"}


def test_liveness_probe(client):
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readiness_probe_reports_database_reachable(client):
    response = client.get("/readyz")
    assert response.status_code == 200
    assert response.json() == {"status": "ready"}


def test_metrics_endpoint_serves_prometheus_format(client):
    response = client.get("/metrics")
    assert response.status_code == 200
    assert "text/plain" in response.headers["content-type"]


def test_create_and_fetch_workload(client):
    created = client.post("/api/v1/workloads", json=WORKLOAD)
    assert created.status_code == 201
    body = created.json()
    assert body["status"] == "discovered"
    assert body["strategy"] == "replatform"

    fetched = client.get(f"/api/v1/workloads/{body['id']}")
    assert fetched.status_code == 200
    assert fetched.json()["name"] == "billing-api"


def test_duplicate_registration_conflicts(client):
    client.post("/api/v1/workloads", json=WORKLOAD)
    duplicate = client.post("/api/v1/workloads", json=WORKLOAD)
    assert duplicate.status_code == 409
    assert "already registered" in duplicate.json()["detail"]


def test_invalid_payload_is_rejected(client):
    response = client.post("/api/v1/workloads", json={**WORKLOAD, "wave": 0})
    assert response.status_code == 422


def test_missing_workload_returns_404(client):
    assert client.get("/api/v1/workloads/9999").status_code == 404


def test_list_workloads_filters_by_wave(client):
    client.post("/api/v1/workloads", json=WORKLOAD)
    client.post("/api/v1/workloads", json={**WORKLOAD, "name": "orders-api", "wave": 2})

    assert len(client.get("/api/v1/workloads").json()) == 2
    wave_two = client.get("/api/v1/workloads", params={"wave": 2}).json()
    assert [w["name"] for w in wave_two] == ["orders-api"]


def test_status_advances_through_full_lifecycle(client):
    workload_id = client.post("/api/v1/workloads", json=WORKLOAD).json()["id"]
    for status in ("assessed", "in_flight", "cutover", "validated"):
        response = client.patch(f"/api/v1/workloads/{workload_id}/status", json={"status": status})
        assert response.status_code == 200, response.text
        assert response.json()["status"] == status


def test_illegal_status_jump_is_rejected(client):
    workload_id = client.post("/api/v1/workloads", json=WORKLOAD).json()["id"]
    response = client.patch(f"/api/v1/workloads/{workload_id}/status", json={"status": "validated"})
    assert response.status_code == 409
    assert "cannot move workload" in response.json()["detail"]


def test_status_update_on_missing_workload_returns_404(client):
    response = client.patch("/api/v1/workloads/9999/status", json={"status": "assessed"})
    assert response.status_code == 404


def test_retire_workload_cannot_cut_over(client):
    workload_id = client.post(
        "/api/v1/workloads", json={**WORKLOAD, "name": "legacy-fax", "strategy": "retire"}
    ).json()["id"]
    client.patch(f"/api/v1/workloads/{workload_id}/status", json={"status": "assessed"})
    client.patch(f"/api/v1/workloads/{workload_id}/status", json={"status": "in_flight"})

    response = client.patch(f"/api/v1/workloads/{workload_id}/status", json={"status": "cutover"})
    assert response.status_code == 409


def test_rollback_then_resume(client):
    workload_id = client.post("/api/v1/workloads", json=WORKLOAD).json()["id"]
    for status in ("assessed", "in_flight", "rolled_back", "assessed"):
        response = client.patch(f"/api/v1/workloads/{workload_id}/status", json={"status": status})
        assert response.status_code == 200, response.text
    assert response.json()["status"] == "assessed"


def test_wave_summary_endpoint(client):
    client.post("/api/v1/workloads", json={**WORKLOAD, "name": "a", "wave": 5})
    client.post("/api/v1/workloads", json={**WORKLOAD, "name": "b", "wave": 5})
    summary = client.get("/api/v1/waves/5/summary").json()
    assert summary["wave"] == 5
    assert summary["total"] == 2
    assert summary["percent_complete"] == 0.0


def test_statuses_endpoint_lists_state_machine(client):
    assert client.get("/api/v1/statuses").json() == [
        "discovered",
        "assessed",
        "in_flight",
        "cutover",
        "validated",
        "rolled_back",
    ]
