# docker-nginx-supply
Docker image for testing and deployment of supply nginx pipeline

To build the docker image:
./buildimage.sh <ENVIRONMENT DEV/QA/PROD> <PROVIDER>
ENVIRONMENT = DEV/QA/PROD
PROVIDER = local (If we are runnning application locally, this need to be provided)
Example:
./buildimage.sh DEV

To run the docker container:
docker run -e "ENV=<ENVIRONMENT>" -e "PROVIDER=<local/ENVIRONMENT>" -p 8000:8000 -p 8001:8001 nginx-supply:latest
ENVIRONMENT = dev/qa/prod
PROVIDER = local/dev/qa/prod (If we are runnning application locally, this need to be provided)
Example:
docker run -e "ENV=dev" -e "PROVIDER=dev" -p 8000:8000 -p 8001:8001 nginx-supply:latest

The build script creates the configurations for dev and builds the docker image. Run runs it. 
