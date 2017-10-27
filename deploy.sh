#!/usr/bin/env bash
set -eo pipefail

# more bash-friendly output for jq
JQ="jq --raw-output --exit-status"

ENV=$1
TAG=$2
PROVIDER=$3
COUNTER_LIMIT=12
# Counter limit will be caluculaed based on sleep seconds

if [[ -z "$ENV" ]] ; then
	echo "Environment should be set on startup with one of the below values"
	echo "ENV must be one of - DEV, QA, PROD or LOCAL"
	exit
fi
if [[ -z "$TAG" ]] ; then
	echo "TAG must be specificed for image"
	exit
fi
if [[ -z "$PROVIDER" ]] ; then
	PROVIDER=$ENV
fi

AWS_REGION=$(eval "echo \$${ENV}_AWS_REGION")
AWS_ACCESS_KEY_ID=$(eval "echo \$${ENV}_AWS_ACCESS_KEY_ID")
AWS_SECRET_ACCESS_KEY=$(eval "echo \$${ENV}_AWS_SECRET_ACCESS_KEY")
AWS_ACCOUNT_ID=$(eval "echo \$${ENV}_AWS_ACCOUNT_ID")
AWS_REPOSITORY=$(eval "echo \$${ENV}_AWS_REPOSITORY")
AWS_ECS_CLUSTER=$(eval "echo \$${ENV}_AWS_ECS_CLUSTER")
AWS_ECS_SERVICE=$(eval "echo \$${ENV}_AWS_ECS_SERVICE")
family=$(eval "echo \$${ENV}_AWS_ECS_TASK_FAMILY")
AWS_ECS_CONTAINER_NAME=$(eval "echo \$${ENV}_AWS_ECS_CONTAINER_NAME")

echo $APP_NAME

configure_aws_cli() {
	aws --version
	aws configure set aws_access_key_id $AWS_ACCESS_KEY_ID
	aws configure set aws_secret_access_key $AWS_SECRET_ACCESS_KEY
	aws configure set default.region $AWS_REGION
	aws configure set default.output json
	echo "Configured AWS CLI."
}

push_ecr_image() {
	echo "Pushing Docker Image..."
	eval $(aws ecr get-login --region $AWS_REGION --no-include-email)
	docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$AWS_REPOSITORY:$TAG
	echo "Docker Image published."

}

update_cluster_taskdef() {

    make_task_def
    register_definition

}
deploy_cluster() {

    AWS_ECS_SERVICE=$1
    update_result=$(aws ecs update-service --cluster $AWS_ECS_CLUSTER --service $AWS_ECS_SERVICE --task-definition $revision )
    #echo $update_result
    result=$(echo $update_result | $JQ '.service.taskDefinition' )
    echo $result
    if [[ $result != $revision ]]; then
        echo "Error updating service."
        exit 1
    fi

    echo "Update service intialised successfully for deployment"
    return 0
}

make_task_def(){
	task_template='[
		{
				"name": "%s",
				"image": "%s.dkr.ecr.%s.amazonaws.com/%s:%s",
				"essential": true,
				"memory": 500,
				"cpu": 100,
				"environment": [
						{
								"name": "ENV",
								"value": "%s"
						},
						{
								"name": "PROVIDER",
								"value": "%s"
						}						
				],
				"portMappings": [
						{
								"hostPort": 0,
								"containerPort": 8000,
								"protocol": "tcp"
						},
						{
								"hostPort": 0,
								"containerPort": 8001,
								"protocol": "tcp"
						}						
				],
				"mountPoints": [
					{
					  "containerPath": "/nfs_shares",
					  "sourceVolume": "nfs_share",
					  "readOnly": null
					},
					{
					  "containerPath": "/data/nginx",
					  "sourceVolume": "nginxdata",
					  "readOnly": null
					}
				],
				"logConfiguration": {
						"logDriver": "awslogs",
						"options": {
								"awslogs-group": "/aws/ecs/%s",
								"awslogs-region": "%s",
								"awslogs-stream-prefix": "%s_%s"
						}
				}
		}
	]'
	volume_def='[
		{
		  "host": {
			"sourcePath": "/nfs_shares"
		  },
		  "name": "nfs_share"
		},
		{
		  "host": {
			"sourcePath": "/mnt/nginx"
		  },
		  "name": "nginxdata"
		}
	]'
	
	task_def=$(printf "$task_template" $AWS_ECS_CONTAINER_NAME $AWS_ACCOUNT_ID $AWS_REGION $AWS_REPOSITORY $TAG $ENV $PROVIDER $AWS_ECS_CLUSTER $AWS_REGION $AWS_ECS_CLUSTER $ENV)
}

register_definition() {
    if revision=$(aws ecs register-task-definition --container-definitions "$task_def" --volumes "$volume_def" --family $family | $JQ '.taskDefinition.taskDefinitionArn'); then
        echo "Revision: $revision"
    else
        echo "Failed to register task definition"
        return 1
    fi

}

check_service_status() {
        AWS_ECS_SERVICE=$1
        counter=0
	sleep 60
        servicestatus=`aws ecs describe-services --service $AWS_ECS_SERVICE --cluster $AWS_ECS_CLUSTER | $JQ '.services[].events[0].message'`
        while [[ $servicestatus != *"steady state"* ]]
        do
           echo "Current event message : $servicestatus"
           echo "Waiting for 15 sec to check the service status...."
           sleep 15
           servicestatus=`aws ecs describe-services --service $AWS_ECS_SERVICE --cluster $AWS_ECS_CLUSTER | $JQ '.services[].events[0].message'`
           counter=`expr $counter + 1`
           if [[ $counter -gt $COUNTER_LIMIT ]] ; then
                echo "Service does not reach steady state with in 180 seconds. Please check"
                exit 1
           fi
        done
        echo "$servicestatus"
}

configure_aws_cli
push_ecr_image
#deploy_cluster
#check_service_status

update_cluster_taskdef

#Service name will be provided with comma seperated
AWS_ECS_SERVICE_NAMES=`echo ${AWS_ECS_SERVICE} | sed 's/,/ /g' | sed 'N;s/\n//' `
IFS=' ' read -a AWS_ECS_SERVICES <<< $AWS_ECS_SERVICE_NAMES
if [ ${#AWS_ECS_SERVICES[@]} -gt 0 ]; then
     echo "${#AWS_ECS_SERVICES[@]} service are going to be updated"
     for AWS_ECS_SERVICE_NAME in "${AWS_ECS_SERVICES[@]}"
     do
       echo "updating ECS Cluster Service - $AWS_ECS_SERVICE_NAME"
       deploy_cluster "$AWS_ECS_SERVICE_NAME"
       check_service_status "$AWS_ECS_SERVICE_NAME"
     done
else
     echo "Kindly check the service name in Parameter"
     usage
     exit 1
fi
