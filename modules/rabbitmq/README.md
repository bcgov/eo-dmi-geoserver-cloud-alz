# module: rabbitmq

RabbitMQ event bus for GeoServer Cloud catalog sync, run as an internal Container
App with TCP ingress on 5672. Credentials are Key Vault references resolved by
the shared user-assigned identity. Single replica (the event bus is not
horizontally scaled in this scaffold).

Siblings connect using the app `name` as the AMQP host on port 5672 within the
environment. Outputs `name` and `fqdn` for wiring into the service env vars.
