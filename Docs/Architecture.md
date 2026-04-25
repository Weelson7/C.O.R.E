# C.O.R.E. Architecture Specification

## 1. Scope

This document defines the target architecture for C.O.R.E. (Clustered Orchestrated Repurposed Environment): topology, control model, failover behavior, data protection, and operational invariants.

## 2. Architectural Principles

1. Mesh-first operation: all coordination and management traffic is Netbird mesh scoped.
2. Supervisor-driven orchestration: placement and failover decisions are centralized in the Supervisor service.
3. Service-level role assignment: alpha, beta, and gamma are assigned per service, not as permanent node identities.
4. Full runtime portability: every node is capable of running every service container.
5. Scriptable and declarative operations: deployment and validation remain reproducible.
6. Continuous observability and automated remediation for nodes and services.

## 3. Topology Model

### 3.1 Dynamic Node Set

- Nodes are discovered from the active Netbird network membership.
- C.O.R.E does not use a fixed global node-role model.
- Any node can be selected for any service role by the Supervisor.

### 3.2 Supervisor Bootstrap

- The first initiated node of the C.O.R.E mesh is the primary Supervisor node.
- This node is referred to as node 0 in operational policy.
- By default, node 0 is the alpha node for every service.
- By default, no beta or gamma node is assigned for any service until explicitly configured.

### 3.3 Sub-Supervisor

- The Supervisor can designate one node as sub-supervisor.
- The sub-supervisor takes over Supervisor responsibilities if the primary Supervisor fails.

## 4. Network Architecture

### 4.1 Overlay Network

- Network fabric: Netbird-managed WireGuard mesh.
- Inter-node trust boundary: mesh subnet only.
- LAN adjacency is not a security boundary.

### 4.2 Node Inventory Source

- The canonical node inventory is the current Netbird network membership.
- Supervisor decisions and health logic must use this live membership view.

### 4.3 Name Resolution and Ingress

- Internal domain namespace: .core.
- Service access model: <service>.core virtual hosts with TLS.
- DNS and ingress placement are controlled by Supervisor role assignments per service.

## 5. Service Architecture

### 5.1 Universal Service Availability

- All service containers are installed on every node.
- Service enablement is controlled by Supervisor policy, not by installation differences.
- Transitional execution mode: node-local deploy scripts are allowed until all service containers are proven stable and operationally reliable.
- Current numbered service inventory spans 0 through 25, with service 25 assigned to Minecraft.

### 5.2 Containerization Policy

- All C.O.R.E services must run as Docker containers by default.
- Netbird and Nginx are the explicit host-native exceptions.
- This standardization is required to simplify service/container start and stop operations across nodes.

### 5.3 Per-Service Role Semantics

For each service, Supervisor can assign:

- alpha node: runs the service and stores primary service data.
- beta node: standby runner; receives daily rsync from alpha and is enabled on alpha failure.
- gamma node: backup tier; receives weekly rsync from alpha.

### 5.4 Orchestration Control Plane

- Swarm and Pulse architecture assumptions are removed from this specification.
- The orchestration authority is the custom Supervisor service.
- The Supervisor service is documented as service x_Supervisor.
- The Indexer landing page is hosted on the Supervisor path: Supervisor node by default, sub-supervisor node on Supervisor failure.

## 6. Data Architecture

### 6.1 Service-Level Durability

Durability is defined per service assignment:

1. Primary dataset on the assigned alpha node.
2. Daily synchronized replica on assigned beta node (if configured).
3. Weekly synchronized replica on assigned gamma node (if configured).

### 6.2 Replication Policy

- Alpha to beta: rsync daily.
- Alpha to gamma: rsync weekly.
- Replication jobs are scheduled, tracked, and validated by Supervisor.

### 6.3 Data Priority Classes

1. Critical: configs, orchestration state, service metadata, and stateful workload data.
2. High: application libraries and user-generated content.
3. Recoverable: cache and transient artifacts.

## 7. Observability and Control

### 7.1 Health Monitoring

- Supervisor monitors node health for all discovered Netbird nodes.
- Supervisor monitors container health for managed services.
- Health state is materialized for automation and operator diagnostics.

### 7.2 Automated Actions

- Promote beta service instance on alpha failure.
- Enable service containers on beta as part of failover.
- Trigger backup orchestration between assigned role nodes.
- Reboot unhealthy nodes when configured policy thresholds are met.

## 8. Security Architecture

### 8.1 Access Model

- Mesh-only administrative surface.
- SSH key-based authentication.
- Principle of least exposure for service ports.

### 8.2 Proxy and Service Security Baseline

- TLS for all .core service endpoints.
- Centralized authentication policy at ingress.
- Security headers enforced at proxy boundary where applicable.

### 8.3 Secret Handling

- Runtime secrets are separated from version-controlled assets.
- Supervisor credentials and service credentials are scoped and isolated.
- Backup replicas containing sensitive material require protected storage and transfer paths.

## 9. Deployment Architecture

### 9.1 Deployment Unit

Each service is a self-contained deployment unit with:

1. idempotent deployment script,
2. service runtime definition,
3. ingress virtual host definition when applicable,
4. post-deploy validation requirements.

### 9.2 Control Exception

Service x_Supervisor is the control exception and defines:

1. node discovery from Netbird,
2. service role assignments,
3. backup orchestration,
4. failover decisions and activation,
5. node and container health enforcement.

### 9.3 Deployment Contract

Deployment process must guarantee:

1. dependency installation,
2. service activation,
3. configuration validation,
4. DNS and ingress verification where applicable,
5. runtime health confirmation,
6. Supervisor policy compatibility.

### 9.4 Transition Mode

- Current rollout phase permits node-local deployment and activation flows.
- This temporary mode remains valid until all services are confirmed container-stable across the node set.
- Once container stability is guaranteed for all services, Supervisor-orchestrated activation becomes the mandatory execution path.

## 10. Failure Domain Specifications

### 10.1 Alpha Node Failure (Per Service)

- Assigned beta node becomes active runner for that service when available.
- If no beta exists, service remains degraded until manual or policy-driven reassignment.

### 10.2 Supervisor Node Failure

- Assigned sub-supervisor takes over control-plane responsibilities.
- If no sub-supervisor exists, control-plane functions are degraded until Supervisor is restored.

### 10.3 Role Node Failure

- Loss of gamma reduces backup depth only.
- Loss of beta removes fast failover for affected services.

## 11. Operational Targets

| Scenario | RPO | RTO |
|---|---:|---:|
| Service alpha failover to beta | <= 24h for services with daily beta sync | < 15 min for supervised failover path |
| Service recovery with gamma only | <= 7d for services with weekly gamma sync | < 4h baseline restoration |
| Supervisor failover to sub-supervisor | Control state dependent on last synchronized policy state | < 15 min target |

## 12. Naming and Interface Standards

1. Domain namespace: <service>.core and <node>.core.
2. Container namespace: core-<service>.
3. Service docs follow a fixed section contract for operational consistency.
4. Supervisor service documentation label is x_Supervisor.

## 13. Governance Constraint

Any architectural change that alters trust boundaries, service role semantics, durability guarantees, Supervisor behavior, or failover policy requires explicit update of this specification and impacted service-level documents.
