"""Unit tests for ClawOffice Swarms HTTP + MCP runtime bridge."""

from __future__ import annotations

import json
import unittest
from unittest.mock import patch

from starlette.testclient import TestClient

import swarms_bridge as sb


class FakeLLM:
    def __init__(self, name: str) -> None:
        self.name = name
        self.usage = {
            "input_tokens": 2,
            "output_tokens": 3,
            "cached_tokens": 0,
            "reasoning_tokens": 0,
            "total_tokens": 5,
        }

    def run(self, task=None, messages=None, **kwargs):
        return f"[{self.name}] ok"

    def __call__(self, task=None, **kwargs):
        return self.run(task=task, **kwargs)


class SwarmsBridgeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.client = TestClient(sb.app)

    def test_health_and_types(self) -> None:
        r = self.client.get("/health")
        self.assertEqual(r.status_code, 200)
        body = r.json()
        self.assertEqual(body["status"], "ok")
        self.assertEqual(body["service"], "clawoffice-swarms-daemon")
        self.assertEqual(body["bridge_version"], sb.BRIDGE_VERSION)
        self.assertIn("SequentialWorkflow", body["supported_swarm_types"])

        rt = self.client.get("/v1/swarm/types")
        self.assertEqual(rt.status_code, 200)
        self.assertGreaterEqual(len(rt.json()["swarm_types"]), 8)

    def test_mcp_initialize_list_and_status_call(self) -> None:
        init_res = self.client.post(
            "/mcp",
            json={"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        )
        self.assertEqual(init_res.status_code, 200)
        self.assertEqual(init_res.json()["result"]["serverInfo"]["name"], "clawoffice-swarms-mcp")
        sid = init_res.headers.get("Mcp-Session-Id")
        self.assertTrue(sid)

        list_res = self.client.post(
            "/mcp",
            headers={"Mcp-Session-Id": sid},
            json={"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
        )
        self.assertEqual(list_res.status_code, 200)
        tools = [t["name"] for t in list_res.json()["result"]["tools"]]
        self.assertIn("swarm_run", tools)
        self.assertIn("swarm_status", tools)

        call_res = self.client.post(
            "/mcp",
            headers={"Mcp-Session-Id": sid},
            json={
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": "swarm_status", "arguments": {}},
            },
        )
        self.assertEqual(call_res.status_code, 200)
        txt = call_res.json()["result"]["content"][0]["text"]
        self.assertEqual(json.loads(txt)["status"], "ok")

    def test_secret_redaction_and_evren_headers(self) -> None:
        prov = sb.ProviderSpec(
            kind="evren",
            base_url="https://evren-llmapi.ssyz.org.tr/v1",
            api_key="evren_llm_super_secret_value_123",
            auth_style="bearerAndXApiKey",
        )
        headers = sb.build_extra_headers(prov)
        self.assertEqual(headers["X-API-Key"], "evren_llm_super_secret_value_123")
        self.assertEqual(headers["Authorization"], "Bearer evren_llm_super_secret_value_123")
        redacted = sb.redact_secrets(
            "failed with evren_llm_super_secret_value_123 and Bearer abcdefgh12345",
            [prov.api_key],
        )
        self.assertNotIn("evren_llm_super_secret_value_123", redacted)
        self.assertNotIn("abcdefgh12345", redacted)

    def test_swarm_run_executes_sequential_and_concurrent_with_swarms_router(self) -> None:
        def fake_build(spec: sb.AgentSpec, workspace_path=None, allow_local_edits=False, **kwargs):
            return sb.Agent(
                agent_name=spec.name,
                agent_description=spec.title,
                system_prompt=spec.system_prompt or "test",
                llm=FakeLLM(spec.name),
                model_name=spec.model_name,
                max_loops=1,
                tools=None,
                print_on=False,
                verbose=False,
                autosave=False,
                reasoning_prompt_on=False,
            )

        with patch.object(sb, "build_swarms_agent", side_effect=fake_build):
            for stype in ("SequentialWorkflow", "ConcurrentWorkflow", "MixtureOfAgents"):
                res = self.client.post(
                    "/v1/swarm/run",
                    json={
                        "task": "Mimari analiz yap",
                        "swarm_type": stype,
                        "max_loops": 1,
                        "agents": [
                            {"name": "Atlas", "title": "Mimar", "model_name": "m1"},
                            {"name": "Kodcu", "title": "Swift", "model_name": "m2"},
                        ],
                    },
                )
                self.assertEqual(res.status_code, 200, res.text)
                body = res.json()
                self.assertEqual(body["status"], "completed")
                self.assertEqual(body["swarm_type"], stype)
                self.assertGreaterEqual(len(body["steps"]), 1)
                self.assertIn("ok", body["final_output"])

    def test_choose_auto_swarm_type(self) -> None:
        self.assertEqual(sb.choose_auto_swarm_type("Tek ajan görevi", 1), "SequentialWorkflow")
        self.assertEqual(sb.choose_auto_swarm_type("Artı ve eksi yönleri tartış", 3), "DebateWithJudge")
        self.assertEqual(sb.choose_auto_swarm_type("Paralel sentez çıkar", 2), "MixtureOfAgents")
        self.assertEqual(sb.choose_auto_swarm_type("Mimari sprint planı yap", 3), "HierarchicalSwarm")

    def test_resilient_llm_cross_provider_failover_skips_auth_failed_provider(self) -> None:
        spec = sb.AgentSpec(
            name="DevOps",
            title="DevOps Engineer",
            model_name="kilo-auto/free",
            provider=sb.ProviderSpec(
                kind="kilo",
                name="Kilo Gateway",
                base_url="https://api.kilo.ai/api/gateway",
                api_key="bad-kilo-token",
                model_name="kilo-auto/free",
                fallback_models=["other-kilo-model"],
            ),
            fallback_provider=sb.ProviderSpec(
                kind="evren",
                name="EVREN",
                base_url="https://evren.example/v1",
                api_key="evren-key",
                auth_style="bearerAndXApiKey",
                model_name="deepseek-v4.1-flash",
                fallback_models=["qwen3.8-flash-next"],
            ),
        )
        llm = sb.ResilientSwarmsLLM(spec)
        calls = []

        def fake_http(self_llm, prov, model, task=None, messages=None):
            calls.append((prov.kind, model))
            if prov.kind == "kilo":
                raise RuntimeError("401 AuthenticationError: Your authentication token is invalid")
            return "EVREN failover ok"

        with patch.object(sb.ResilientSwarmsLLM, "_call_http_provider", fake_http):
            out = llm.run("test")

        self.assertEqual(out, "EVREN failover ok")
        # Must skip remaining Kilo models after 401 and fail over directly to EVREN
        self.assertEqual(calls, [("kilo", "kilo-auto/free"), ("evren", "deepseek-v4.1-flash")])
        self.assertEqual(llm.last_used_model, "deepseek-v4.1-flash")

    def test_resilient_llm_retries_on_empty_reasoning_only_output(self) -> None:
        spec = sb.AgentSpec(
            name="Mimar",
            title="Mimar",
            model_name="bad-reasoning-only",
            provider=sb.ProviderSpec(
                kind="openRouter",
                name="OpenRouter",
                base_url="https://openrouter.ai/api/v1",
                api_key="or-key",
                model_name="bad-reasoning-only",
                fallback_models=["good-model"],
            ),
        )
        llm = sb.ResilientSwarmsLLM(spec)

        class FakeMsg:
            def __init__(self, content):
                self.content = content

        class FakeChoice:
            def __init__(self, content):
                self.message = FakeMsg(content)

        class FakeResp:
            def __init__(self, content):
                self.choices = [FakeChoice(content)]
                self.usage = None

        seen = []

        def fake_completion(**kwargs):
            seen.append(kwargs["model"])
            if kwargs["model"] == "bad-reasoning-only":
                return FakeResp(None)
            return FakeResp("<think>internal</think>Final answer")

        import litellm
        with patch.object(litellm, "completion", side_effect=fake_completion):
            out = llm.run("ping")

        self.assertEqual(out, "Final answer")
        self.assertEqual(seen, ["bad-reasoning-only", "good-model"])

    def test_runtime_load_tracker_idle_busy_and_cooldowns(self) -> None:
        sb.RUNTIME_TRACKER.clear()
        try:
            evren = sb.ProviderSpec(
                kind="evren",
                name="EVREN",
                base_url="https://evren.example/v1",
                api_key="evren-key",
            )
            openrouter = sb.ProviderSpec(
                kind="openRouter",
                name="OpenRouter",
                base_url="https://openrouter.ai/api/v1",
                api_key="or-key",
            )
            kilo = sb.ProviderSpec(
                kind="kilo",
                name="Kilo",
                base_url="https://api.kilo.ai/api/gateway",
                api_key="kilo-key",
            )

            cand_busy = (evren, "model-busy")
            cand_idle = (evren, "model-idle")
            cand_cooled = (openrouter, "model-rate-limited")

            sb.RUNTIME_TRACKER.begin_in_flight(evren, "model-busy")
            sb.RUNTIME_TRACKER.mark_failure(openrouter, "model-rate-limited", RuntimeError("429 Too Many Requests"))

            ordered = sb.RUNTIME_TRACKER.order_candidates([cand_busy, cand_cooled, cand_idle])
            self.assertEqual(ordered, [cand_idle, cand_busy, cand_cooled])
            sb.RUNTIME_TRACKER.end_in_flight(evren, "model-busy")

            # 1 transient failure cools only that model; 2nd transient failure triggers provider-level cooldown
            fatal1 = sb.RUNTIME_TRACKER.mark_failure(kilo, "kilo-1", RuntimeError("502 Bad Gateway"))
            self.assertFalse(fatal1)
            self.assertTrue(sb.RUNTIME_TRACKER.is_cooled(kilo, "kilo-1"))
            self.assertFalse(sb.RUNTIME_TRACKER.is_cooled(kilo, "kilo-2"))

            fatal2 = sb.RUNTIME_TRACKER.mark_failure(kilo, "kilo-2", RuntimeError("504 Gateway Timeout"))
            self.assertFalse(fatal2)
            self.assertTrue(sb.RUNTIME_TRACKER.is_cooled(kilo, "kilo-3"))

            # Fatal error cools the whole provider immediately
            fatal3 = sb.RUNTIME_TRACKER.mark_failure(openrouter, "model-other", RuntimeError("401 Unauthorized"))
            self.assertTrue(fatal3)
            self.assertTrue(sb.RUNTIME_TRACKER.is_cooled(openrouter, "fresh-model"))
        finally:
            sb.RUNTIME_TRACKER.clear()

    def test_resilient_llm_multi_hop_fallback_providers_and_telemetry(self) -> None:
        sb.RUNTIME_TRACKER.clear()
        try:
            kilo = sb.ProviderSpec(
                kind="kilo",
                name="Kilo Gateway",
                base_url="https://api.kilo.ai/api/gateway",
                api_key="kilo-bad-token",
                model_name="bad-kilo",
            )
            openrouter = sb.ProviderSpec(
                kind="openRouter",
                name="OpenRouter",
                base_url="https://openrouter.ai/api/v1",
                api_key="or-token",
                model_name="or-rate-limited",
            )
            evren = sb.ProviderSpec(
                kind="evren",
                name="EVREN",
                base_url="https://evren.example/v1",
                api_key="evren-good-token",
                auth_style="bearerAndXApiKey",
                model_name="deepseek-v4.1-flash",
            )
            spec = sb.AgentSpec(
                name="DevOps",
                title="DevOps Engineer",
                model_name="bad-kilo",
                provider=kilo,
                fallback_provider=openrouter,
                fallback_providers=[openrouter, evren],
            )
            telemetry = sb.SwarmTelemetryCollector()
            llm = sb.ResilientSwarmsLLM(spec, telemetry=telemetry)
            calls = []

            def fake_http(self_llm, prov, model, task=None, messages=None):
                calls.append((prov.kind, model))
                if prov.kind == "kilo":
                    raise RuntimeError("401 AuthenticationError")
                if prov.kind == "openRouter":
                    raise RuntimeError("429 Too Many Requests")
                return "Multi-hop failover ok"

            with patch.object(sb.ResilientSwarmsLLM, "_call_http_provider", fake_http):
                out = llm.run("deploy check")

            self.assertEqual(out, "Multi-hop failover ok")
            self.assertEqual(
                calls,
                [("kilo", "bad-kilo"), ("openRouter", "or-rate-limited"), ("evren", "deepseek-v4.1-flash")],
            )
            tdict = telemetry.to_dict()
            self.assertEqual(len(tdict["failed_candidates"]), 2)
            self.assertTrue(tdict["failed_candidates"][0]["is_provider_fatal"])
            self.assertFalse(tdict["failed_candidates"][1]["is_provider_fatal"])
            self.assertEqual(tdict["used_routes"][0]["provider_kind"], "evren")
            self.assertTrue(tdict["used_routes"][0]["used_fallback"])
        finally:
            sb.RUNTIME_TRACKER.clear()

    def test_resilient_llm_cancellation_raises_immediately(self) -> None:
        sb.RUNTIME_TRACKER.clear()
        spec = sb.AgentSpec(
            name="Mimar",
            title="Mimar",
            model_name="deepseek-v4.1-flash",
            provider=sb.ProviderSpec(
                kind="evren",
                name="EVREN",
                base_url="https://evren.example/v1",
                api_key="evren-key",
                model_name="deepseek-v4.1-flash",
            ),
        )
        llm = sb.ResilientSwarmsLLM(spec, cancel_check=lambda: True)
        with patch.object(sb.ResilientSwarmsLLM, "_call_http_provider", side_effect=AssertionError("Should not invoke HTTP when cancelled")):
            with self.assertRaises(sb.SwarmCancelledError):
                llm.run("task")

    def test_topologies_route_internal_agents_through_resilient_llm_and_emit_telemetry(self) -> None:
        sb.RUNTIME_TRACKER.clear()
        try:
            import litellm

            evren = {
                "kind": "evren",
                "name": "EVREN",
                "base_url": "https://evren.example/v1",
                "api_key": "evren-key",
                "auth_style": "bearerAndXApiKey",
                "model_name": "deepseek-v4.1-flash",
                "fallback_models": ["qwen3.8-flash-next"],
            }
            agents = [
                {
                    "name": "Mimar",
                    "title": "Kıdemli Mimar",
                    "system_prompt": "Mimari analiz yap.",
                    "model_name": "deepseek-v4.1-flash",
                    "temperature": 0.2,
                    "role": "director",
                    "provider": evren,
                },
                {
                    "name": "Kodcu",
                    "title": "Swift Geliştirici",
                    "system_prompt": "Swift kodla.",
                    "model_name": "deepseek-v4.1-flash",
                    "temperature": 0.2,
                    "role": "developer",
                    "provider": evren,
                },
            ]

            def fake_http(self_llm, prov, model, task=None, messages=None):
                return f"[{self_llm.spec.name}] Ajan çıktısı tamamlandı."

            def fail_bare_litellm(**kwargs):
                raise AssertionError(f"Bare litellm.completion called bypassing ResilientSwarmsLLM: {kwargs.get('model')}")

            with patch.object(sb.ResilientSwarmsLLM, "_call_http_provider", fake_http), patch.object(
                litellm, "completion", side_effect=fail_bare_litellm
            ):
                for topo in ("MajorityVoting", "HierarchicalSwarm", "MultiAgentRouter", "PlannerWorkerSwarm", "GroupChat"):
                    res = self.client.post(
                        "/v1/swarm/run",
                        json={
                            "task": f"{topo} topolojisi için koordineli yanıt üret",
                            "swarm_type": topo,
                            "max_loops": 1,
                            "agents": agents,
                            "director": agents[0],
                        },
                    )
                    self.assertEqual(res.status_code, 200, f"{topo} failed: {res.text}")
                    body = res.json()
                    self.assertEqual(body["status"], "completed", f"{topo} status: {body}")
                    self.assertTrue(body["final_output"].strip(), f"{topo} empty final_output")
                    self.assertGreaterEqual(len(body["telemetry"]["used_routes"]), 1, f"{topo} missing telemetry")
        finally:
            sb.RUNTIME_TRACKER.clear()


if __name__ == "__main__":
    unittest.main()
