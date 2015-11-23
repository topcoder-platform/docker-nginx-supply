# docker-nginx-supply
Docker image for testing and deployment of supply nginx pipeline

To build the docker image:
docker build -t appiriodevops/nginx-supply:latest .

To run the docker container:
docker build -d -e "ENV=<ENVIRONMENT>" -P 8000:8000 appiriodevops/nginx-supply

The build script creates the configurations for dev and builds the docker image. Run runs it.
