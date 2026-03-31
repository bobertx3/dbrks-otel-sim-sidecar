from __future__ import annotations

import logging
import os
from dataclasses import dataclass

from opentelemetry import _logs as otel_logs
from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter as OTLPMetricExporterGrpc
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import SimpleLogRecordProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor


# Sidecar collector definitions: which signals each collector handles
SIDECAR_COLLECTORS = [
    {
        "name": "Fluent Bit",
        "signals": ["logs"],
        "port": 4318,
        "protocol": "http",
        "description": "Lightweight, C-based log processor",
        "info": (
            "Fluent Bit is a super-lightweight log processor and forwarder written in C. "
            "It's the de facto standard for log collection in Kubernetes — deployed as a "
            "DaemonSet on every node. With a ~1MB footprint and 300+ plugins, it tails "
            "container logs, parses them, and routes to any backend. Purpose-built for logs, "
            "not metrics or traces."
        ),
        "config_format": "YAML",
        "config_lines": "~12",
    },
    {
        "name": "Telegraf",
        "signals": ["metrics"],
        "port": 4319,
        "protocol": "grpc",
        "description": "InfluxData's metrics-focused agent",
        "info": (
            "Telegraf is InfluxData's plugin-driven agent for collecting and reporting metrics. "
            "It supports OTLP input via gRPC and OTLP/HTTP output. Note: Telegraf's internal "
            "metric model converts OTLP to Influx line protocol, which loses histogram min/max "
            "fields. A namepass filter restricts output to gauges and sums only."
        ),
        "config_format": "TOML",
        "config_lines": "~25",
    },
    {
        "name": "Grafana Alloy",
        "signals": ["logs", "metrics", "traces"],
        "port": 4320,
        "protocol": "http",
        "description": "Grafana's OpenTelemetry-native collector",
        "info": (
            "Grafana Alloy (successor to Grafana Agent) is an OpenTelemetry-native collector "
            "that handles all three signal types. It's designed for the Grafana ecosystem "
            "(Loki, Mimir, Tempo) but works with any OTLP-compatible backend. Uses a "
            "component-based pipeline model with its own 'River' config language. "
            "Good choice for teams already using Grafana Cloud."
        ),
        "config_format": "River",
        "config_lines": "~15",
    },
    {
        "name": "Vector",
        "signals": ["logs"],
        "port": 4322,
        "protocol": "http",
        "description": "Rust-based, high-performance data pipeline",
        "info": (
            "Vector is a high-performance observability data pipeline written in Rust by "
            "Datadog. It excels at log collection and transformation with very low resource "
            "usage and high throughput — often used as a Logstash replacement. Features a "
            "powerful transform layer (VRL — Vector Remap Language) for parsing and enriching "
            "data in-flight. OTLP metrics forwarding has limitations."
        ),
        "config_format": "YAML/TOML",
        "config_lines": "~10",
    },
    {
        "name": "OTel Collector",
        "signals": ["logs", "metrics", "traces"],
        "port": 4323,
        "protocol": "http",
        "description": "The reference OTel Collector implementation",
        "info": (
            "The OpenTelemetry Collector is the official, vendor-neutral reference "
            "implementation from the CNCF OpenTelemetry project. It handles all three "
            "signal types natively and is the most widely deployed OTel collector. "
            "Extensible via receivers, processors, and exporters. The 'contrib' distribution "
            "includes 200+ community-maintained components. The standard choice for "
            "greenfield OTel deployments."
        ),
        "config_format": "YAML",
        "config_lines": "~8",
    },
]


@dataclass(frozen=True)
class EmitterConfig:
    databricks_host: str
    databricks_token: str
    service_name: str
    direct_spans_table: str
    direct_logs_table: str
    direct_metrics_table: str

    @classmethod
    def from_env(cls) -> "EmitterConfig":
        import logging
        logger = logging.getLogger(__name__)

        # Try explicit token, then SDK default auth (Databricks Apps runtime)
        token = os.getenv("DATABRICKS_TOKEN", "")
        if not token:
            try:
                from databricks.sdk import WorkspaceClient
                w = WorkspaceClient()
                # Use the SDK's token provider for Apps SP auth
                header = w.config.authenticate()
                if header and "Authorization" in header:
                    token = header["Authorization"].replace("Bearer ", "")
                logger.info(f"Got token from Databricks SDK: {bool(token)}")
            except Exception as e:
                logger.warning(f"SDK auth fallback failed: {e}")

        required = {
            "DATABRICKS_HOST": os.getenv("DATABRICKS_HOST", ""),
            "OTEL_SERVICE_NAME": os.getenv("OTEL_SERVICE_NAME", ""),
            "OTEL_DIRECT_SPANS_TABLE": os.getenv("OTEL_DIRECT_SPANS_TABLE", ""),
            "OTEL_DIRECT_LOGS_TABLE": os.getenv("OTEL_DIRECT_LOGS_TABLE", ""),
            "OTEL_DIRECT_METRICS_TABLE": os.getenv("OTEL_DIRECT_METRICS_TABLE", ""),
        }
        missing = [k for k, v in required.items() if not v]
        if not token:
            missing.insert(0, "DATABRICKS_TOKEN")
        if missing:
            raise ValueError(f"Missing required .env keys: {', '.join(missing)}")

        return cls(
            databricks_host=required["DATABRICKS_HOST"].rstrip("/"),
            databricks_token=token,
            service_name=required["OTEL_SERVICE_NAME"],
            direct_spans_table=required["OTEL_DIRECT_SPANS_TABLE"],
            direct_logs_table=required["OTEL_DIRECT_LOGS_TABLE"],
            direct_metrics_table=required["OTEL_DIRECT_METRICS_TABLE"],
        )


class OTelEmitter:
    def __init__(self, cfg: EmitterConfig, sidecar_mode: bool | None = None) -> None:
        self.cfg = cfg
        if sidecar_mode is not None:
            self.sidecar_mode = sidecar_mode
        else:
            self.sidecar_mode = os.getenv("OTEL_SIDECAR_MODE", "false").lower() in ("true", "1", "yes")

        # In direct mode, emitter sends to direct_ tables.
        # In sidecar mode, the collectors set their own table names — these aren't used by exporters.
        self._active_spans_table = cfg.direct_spans_table
        self._active_logs_table = cfg.direct_logs_table
        self._active_metrics_table = cfg.direct_metrics_table

        resource = Resource.create(
            {
                "service.name": cfg.service_name,
                "service.version": "0.1.0",
                "deployment.environment": "local-simulator",
            }
        )

        # --- Traces ---
        self.tracer_provider = TracerProvider(resource=resource)
        self.traces_endpoint = f"{cfg.databricks_host}/api/2.0/tracing/otel/v1/traces"
        if self.sidecar_mode:
            for c in SIDECAR_COLLECTORS:
                if "traces" in c["signals"]:
                    exp = OTLPSpanExporter(
                        endpoint=f"http://localhost:{c['port']}/v1/traces", headers={}
                    )
                    self.tracer_provider.add_span_processor(SimpleSpanProcessor(exp))
        else:
            exp = OTLPSpanExporter(
                endpoint=self.traces_endpoint, headers=self._headers(self._active_spans_table)
            )
            self.tracer_provider.add_span_processor(SimpleSpanProcessor(exp))
        self.tracer = self.tracer_provider.get_tracer(cfg.service_name)

        # --- Logs ---
        self.logger_provider = LoggerProvider(resource=resource)
        self.logs_endpoint = f"{cfg.databricks_host}/api/2.0/tracing/otel/v1/logs"
        if self.sidecar_mode:
            for c in SIDECAR_COLLECTORS:
                if "logs" in c["signals"]:
                    exp = OTLPLogExporter(
                        endpoint=f"http://localhost:{c['port']}/v1/logs", headers={}
                    )
                    self.logger_provider.add_log_record_processor(SimpleLogRecordProcessor(exp))
        else:
            exp = OTLPLogExporter(
                endpoint=self.logs_endpoint, headers=self._headers(self._active_logs_table)
            )
            self.logger_provider.add_log_record_processor(SimpleLogRecordProcessor(exp))

        self.otel_handler = LoggingHandler(
            level=logging.INFO, logger_provider=self.logger_provider
        )
        self.logger = logging.getLogger(f"{cfg.service_name}.simulator")
        self.logger.handlers = []
        self.logger.addHandler(self.otel_handler)
        self.logger.setLevel(logging.INFO)

        # --- Metrics ---
        self.metric_readers: list[PeriodicExportingMetricReader] = []
        self.metrics_endpoint = f"{cfg.databricks_host}/api/2.0/otel/v1/metrics"
        if self.sidecar_mode:
            for c in SIDECAR_COLLECTORS:
                if "metrics" in c["signals"]:
                    if c["protocol"] == "grpc":
                        exp = OTLPMetricExporterGrpc(
                            endpoint=f"localhost:{c['port']}", insecure=True
                        )
                    else:
                        exp = OTLPMetricExporter(
                            endpoint=f"http://localhost:{c['port']}/v1/metrics", headers={}
                        )
                    reader = PeriodicExportingMetricReader(exp, export_interval_millis=5_000)
                    self.metric_readers.append(reader)
        else:
            exp = OTLPMetricExporter(
                endpoint=self.metrics_endpoint, headers=self._headers(self._active_metrics_table)
            )
            reader = PeriodicExportingMetricReader(exp, export_interval_millis=5_000)
            self.metric_readers.append(reader)

        self.meter_provider = MeterProvider(
            resource=resource, metric_readers=self.metric_readers
        )
        self.meter = self.meter_provider.get_meter(cfg.service_name)

        self.error_counter = self.meter.create_counter(
            "app.error_count", description="Total simulated errors", unit="errors"
        )
        self.latency_hist = self.meter.create_histogram(
            "app.request_latency_ms",
            description="Simulated request latency",
            unit="ms",
        )
        self.incident_counter = self.meter.create_counter(
            "app.incident.count", description="Total incidents", unit="incidents"
        )
        self.mttr_hist = self.meter.create_histogram(
            "app.incident.mttr_minutes",
            description="Mean time to resolve",
            unit="min",
        )
        self.revenue_hist = self.meter.create_histogram(
            "app.incident.revenue_impact_usd",
            description="Revenue impact per incident",
            unit="USD",
        )
        self.users_hist = self.meter.create_histogram(
            "app.incident.users_affected",
            description="Users affected per incident",
            unit="users",
        )

    def _headers(self, table_name: str) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self.cfg.databricks_token}",
            "X-Databricks-UC-Table-Name": table_name,
            "X-Databricks-Workspace-Url": self.cfg.databricks_host,
        }

    # Realistic child span templates per domain
    _CHILD_SPANS = {
        "applications": [
            ("auth.validate", 0.003, 0.012),
            ("cache.lookup", 0.001, 0.008),
            ("db.query", 0.005, 0.030),
            ("serialize.response", 0.001, 0.005),
        ],
        "infrastructure": [
            ("k8s.api.check", 0.002, 0.010),
            ("resource.probe", 0.003, 0.015),
            ("metrics.collect", 0.002, 0.008),
        ],
        "networking": [
            ("dns.resolve", 0.001, 0.006),
            ("tcp.connect", 0.002, 0.012),
            ("tls.handshake", 0.003, 0.015),
        ],
    }

    def emit_trace(
        self,
        *,
        domain: str,
        event: str,
        label: str,
        attributes: dict[str, object],
        child_name: str | None = None,
    ) -> None:
        import time
        import random

        children = list(self._CHILD_SPANS.get(domain, self._CHILD_SPANS["applications"]))
        # Pick 2-4 child spans, always include the domain-specific ones
        num_children = random.randint(2, min(4, len(children)))
        selected = random.sample(children, num_children)

        with self.tracer.start_as_current_span(
            name=label,
            attributes={"domain": domain, "event": event, **attributes},
        ) as parent:
            parent.add_event("simulator.triggered", {"event.label": label})
            time.sleep(random.uniform(0.005, 0.015))

            for child_label, min_dur, max_dur in selected:
                with self.tracer.start_as_current_span(
                    child_label, attributes={"component": child_label, "domain": domain}
                ) as child:
                    time.sleep(random.uniform(min_dur, max_dur))

            # Error events get an extra downstream.call child
            if child_name:
                with self.tracer.start_as_current_span(
                    child_name, attributes={"component": child_name, **attributes}
                ) as child:
                    child.add_event("simulator.child_step")
                    time.sleep(random.uniform(0.005, 0.025))

            time.sleep(random.uniform(0.003, 0.010))

    def emit_log(
        self,
        *,
        level: int,
        message: str,
        domain: str,
        event: str,
        extra: dict[str, object] | None = None,
    ) -> None:
        payload = {"domain": domain, "event": event}
        if extra:
            payload.update(extra)
        self.logger.log(level, message, extra=payload)

    def emit_metrics(
        self,
        *,
        domain: str,
        route: str,
        latency_ms: float,
        error: bool = False,
    ) -> None:
        attrs = {"domain": domain, "route": route}
        self.latency_hist.record(latency_ms, attrs)
        if error:
            self.error_counter.add(1, attrs)

    def emit_incident_trace(
        self,
        *,
        domain: str,
        event: str,
        label: str,
        attributes: dict[str, object],
        incident_attrs: dict[str, object],
        child_name: str | None = None,
    ) -> None:
        merged = {**attributes, **incident_attrs}
        self.emit_trace(
            domain=domain,
            event=event,
            label=label,
            attributes=merged,
            child_name=child_name,
        )

    def emit_incident_metrics(
        self,
        *,
        domain: str,
        severity: str,
        priority: str,
        service_name: str,
        mttr_minutes: float,
        revenue_impact_usd: float,
        users_affected: int,
    ) -> None:
        attrs = {
            "app.domain": domain,
            "app.incident.severity": severity,
            "app.incident.priority": priority,
            "service.name": service_name,
        }
        self.incident_counter.add(1, attrs)
        if mttr_minutes > 0:
            self.mttr_hist.record(mttr_minutes, attrs)
        if revenue_impact_usd > 0:
            self.revenue_hist.record(revenue_impact_usd, attrs)
        if users_affected > 0:
            self.users_hist.record(float(users_affected), attrs)

    def flush(self) -> None:
        self.tracer_provider.force_flush(timeout_millis=10000)
        self.logger_provider.force_flush(timeout_millis=10000)
        for reader in self.metric_readers:
            reader.collect(timeout_millis=10000)
        self.meter_provider.force_flush(timeout_millis=10000)

    def shutdown(self) -> None:
        """Cleanly shut down all providers (flush + release resources)."""
        try:
            self.flush()
        except Exception:
            pass
        try:
            self.tracer_provider.shutdown()
        except Exception:
            pass
        try:
            self.logger_provider.shutdown()
        except Exception:
            pass
        try:
            self.meter_provider.shutdown()
        except Exception:
            pass
