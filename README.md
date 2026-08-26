# docker-nginx-supply

Docker image for testing and deployment of the Supply nginx pipeline.

## Platform UI proxy

Requests to `/opportunities`, `/thrive`, and their child routes on the apex
Topcoder host are reverse-proxied to the matching Platform UI hostname. The
browser URL therefore remains on the public Topcoder host. Requests on the
`www` hostname are canonicalized to the apex host at the public edge.

Platform UI currently publishes root-relative asset URLs. On the apex server,
the `/static/` tree and exact public files referenced by its HTML are therefore
proxied to Platform UI as well. The `www` server keeps its existing legacy
asset routes; this is why Platform UI URLs are canonicalized instead of being
served in place.

Set `ENV_PLATFORM_UI_ORIGIN` in the nginx build variables to the environment's
CloudFront distribution hostname, without a scheme or path. The proxy connects
to this hostname directly while sending `platform-ui.<environment-domain>` as
the TLS server name and HTTP host. This is required because private Topcoder
DNS maps the Platform UI alias back to the root load balancer.

Set `ENV_PLATFORM_UI_RESOLVER` to the AmazonProvidedDNS IPv4 address for the
nginx task VPC (the primary VPC CIDR base plus two; for example, `10.15.0.2` in
development). The Platform UI proxy uses this scoped resolver because the
legacy global nginx resolvers are not reachable from the Fargate network. Both
variables are validated during the build so a missing or malformed deployment
configuration fails before an image is published.

The public load balancer must forward `/opportunities`, `/opportunities/*`,
`/thrive`, and `/thrive/*` to the Supply nginx target group rather than
redirect to the Platform UI hostname.

To build the docker image:

```shell
docker build -t appiriodevops/nginx-supply:latest .
```

To run the docker container:

```shell
docker build -d -e "ENV=<ENVIRONMENT>" -P 8000:8000 appiriodevops/nginx-supply
```

The build script creates the configurations for dev and builds the docker image. Run runs it.
