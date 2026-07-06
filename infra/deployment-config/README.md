# Deployment config bundle

This directory holds the deployment-time Spring YAML config bundle for the GeoServer Cloud services.

It is intended to be published into the Container Apps environment as a mounted config directory during Terraform deployment and consumed by the services through the standard Spring Boot config import flow.
