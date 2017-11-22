#!/bin/bash
ENV=$1
PROVIDER=$2
if [[ -z "$ENV" ]] ; then
	echo "Environment should be set on startup with one of the below values"
	echo "ENV must be one of - DEV, QA, PROD or LOCAL"
	exit
fi

echo "$ENV before case conversion"
AWS_REGION=$(eval "echo \$${ENV}_AWS_REGION")
AWS_ACCESS_KEY_ID=$(eval "echo \$${ENV}_AWS_ACCESS_KEY_ID")
AWS_SECRET_ACCESS_KEY=$(eval "echo \$${ENV}_AWS_SECRET_ACCESS_KEY")
AWS_ACCOUNT_ID=$(eval "echo \$${ENV}_AWS_ACCOUNT_ID")
AWS_REPOSITORY=$(eval "echo \$${ENV}_AWS_REPOSITORY")
#APP_NAME

#Converting environment varibale as lower case for build purpose
ENV=`echo "$ENV" | tr '[:upper:]' '[:lower:]'`
echo "$ENV after case conversion"

configure_aws_cli() {
	aws --version
	aws configure set aws_access_key_id $AWS_ACCESS_KEY_ID
	aws configure set aws_secret_access_key $AWS_SECRET_ACCESS_KEY
	aws configure set default.region $AWS_REGION
	aws configure set default.output json
	echo "Configured AWS CLI."
}

rm -rf dist
mkdir -p dist/sites-enabled
mkdir -p dist/includes

cp src/sites-enabled/*conf dist/sites-enabled/
cp src/includes/*conf dist/includes/
cp src/*conf dist/

if [[ "$ENV" == dev ]]; then
	cp -rf src/dev/* dist/
fi

if [[ "$ENV" == qa ]]; then
	cp -rf src/qa/* dist/
fi

if [[ "$PROVIDER" == local ]]; then
	cp -rf src/local/includes/*.conf dist/includes/
fi

if [[ "$ENV" != prod ]]; then
	perl -pi -e "s/\{\{ENV_TLD\}\}/topcoder-$ENV\.com/g" dist/sites-enabled/*conf
	perl -pi -e "s/\{\{ENV_TLD\}\}/topcoder-$ENV\.com/g" dist/includes/*conf
	perl -pi -e "s/\{\{ENV_WWWTC\}\}/wwwtc\.staging\.wpengine\.com/g" dist/sites-enabled/*conf
else
	perl -pi -e "s/\{\{ENV_TLD\}\}/topcoder\.com/g" dist/sites-enabled/*conf
	perl -pi -e "s/\{\{ENV_TLD\}\}/topcoder\.com/g" dist/includes/*conf
	perl -pi -e "s/\{\{ENV_WWWTC\}\}/wwwtc\.wpengine\.com/g" dist/sites-enabled/*conf
fi

perl -pi -e "s/\{\{ENV\}\}/$ENV/g" dist/sites-enabled/*conf
perl -pi -e "s/\{\{ENV\}\}/$ENV/g" dist/includes/*conf

#/root/init_logentries.sh (need to look in image)

if [[ "$PROVIDER" == local ]]; then
	docker build --no-cache -t nginx-supply:latest .
else
	configure_aws_cli
	aws s3 cp "s3://appirio-platform-$ENV/services/common/dockercfg" ~/.dockercfg
	#eval $(aws ecr get-login --region $AWS_REGION --no-include-email)
	# Builds Docker image of the app.
	TAG=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$AWS_REPOSITORY:$CIRCLE_SHA1
	docker build -f ECSDockerfile -t $TAG .
fi
