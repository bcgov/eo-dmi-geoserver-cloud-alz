## ADDED Requirements

### Requirement: JVM services launch via jaz instead of java
Each custom-built GeoServer Cloud service image SHALL launch its Java process using the `jaz` Azure Command Launcher in place of a direct `java` invocation, passing through the same JVM and application arguments the upstream image would otherwise pass to `java`.

#### Scenario: Container entrypoint invokes jaz
- **GIVEN** an Azure Container App running a custom-built jaz image
- **WHEN** the container starts
- **THEN** the container's entrypoint process is `jaz`, invoked with the original upstream `java` arguments (jar path, working directory) preserved, and `jaz` launches the JVM as its child process

#### Scenario: User-provided JVM tuning is preserved
- **GIVEN** a service has explicit `-X*`/`-XX*` JVM flags already set (for example via `JAVA_OPTS` or `JAVA_TOOL_OPTIONS`)
- **WHEN** `jaz` launches the JVM
- **THEN** `jaz` does not override those user-provided tuning flags, unless `JAZ_IGNORE_USER_TUNING=1` is explicitly set on that Container App

#### Scenario: Graceful shutdown is preserved
- **GIVEN** a Container App replica is being scaled down or restarted
- **WHEN** Azure Container Apps sends a termination signal to the container
- **THEN** `jaz` relays the signal to the underlying JVM process and relays the JVM's exit code back to the container runtime, so shutdown behavior is unchanged from the pre-jaz direct `java` launch

### Requirement: Degraded-mode visibility when the base image lacks a certified JDK
If the underlying image does not provide a full, certified JDK, the system SHALL still start the service — `jaz` falls back to launching the JVM without its tuning adjustments — rather than failing to start.

#### Scenario: JRE-only or uncertified JDK detected
- **GIVEN** the container's Java installation is JRE-only, a custom jlink runtime, or an uncertified JDK distribution
- **WHEN** `jaz` launches the JVM
- **THEN** `jaz` prints a warning to standard error, still launches the application, and does not apply its full set of tuning adjustments
