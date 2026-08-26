#!/usr/bin/env bash
set -euo pipefail

ENV="${1:-}"
PROVIDER="${2:-}"

case "${ENV}" in
	DEV | QA | PROD | LOCAL) ;;
	*)
		echo "ENV must be one of - DEV, QA, PROD or LOCAL" >&2
		exit 1
		;;
esac
if [[ -n "${PROVIDER}" && "${PROVIDER}" != local ]]; then
	echo "The optional provider must be local." >&2
	exit 1
fi

ENV_PLATFORM_UI_RESOLVER="${ENV_PLATFORM_UI_RESOLVER:-}"
if [[ -z "${ENV_PLATFORM_UI_RESOLVER}" && "${PROVIDER}" == local ]]; then
	ENV_PLATFORM_UI_RESOLVER="8.8.8.8"
fi

if [[ ! "$ENV_PLATFORM_UI_RESOLVER" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
	! awk -v ip="$ENV_PLATFORM_UI_RESOLVER" 'BEGIN { count = split(ip, octets, "."); if (count != 4) exit 1; for (i = 1; i <= 4; i++) if (octets[i] < 0 || octets[i] > 255) exit 1 }'
then
	echo "ENV_PLATFORM_UI_RESOLVER must be an IPv4 address"
	exit 1
fi

echo "$ENV before case conversion"
# AWS_REGION=$(eval "echo \$${ENV}_AWS_REGION")
# AWS_ACCESS_KEY_ID=$(eval "echo \$${ENV}_AWS_ACCESS_KEY_ID")
# AWS_SECRET_ACCESS_KEY=$(eval "echo \$${ENV}_AWS_SECRET_ACCESS_KEY")
# AWS_ACCOUNT_ID=$(eval "echo \$${ENV}_AWS_ACCOUNT_ID")
# AWS_REPOSITORY=$(eval "echo \$${ENV}_AWS_REPOSITORY")
#APP_NAME

#Converting environment varibale as lower case for build purpose
ENV="$(printf '%s' "${ENV}" | tr '[:upper:]' '[:lower:]')"
echo "$ENV after case conversion"
if [[ "${ENV}" == prod ]]; then
	readonly runtime_www_host='www.topcoder.com'
else
	readonly runtime_www_host="www.topcoder-${ENV}.com"
fi

# configure_aws_cli() {
# 	aws --version
# 	aws configure set aws_access_key_id $AWS_ACCESS_KEY_ID
# 	aws configure set aws_secret_access_key $AWS_SECRET_ACCESS_KEY
# 	aws configure set default.region $AWS_REGION
# 	aws configure set default.output json
# 	echo "Configured AWS CLI."
# }

rm -rf dist
mkdir -p dist/sites-enabled
mkdir -p dist/includes

cp src/sites-enabled/*conf dist/sites-enabled/
cp src/includes/*conf dist/includes/
cp src/*conf dist/
cp -rvf src/customerrorpage dist/

if [[ "$ENV" == dev ]]; then
	echo "" >> dist/security_headers.conf
	echo "add_header 'X-Robots-Tag' noindex always;" >> dist/security_headers.conf
fi

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
	perl -pi -e "s/\{\{ENV_WWWTC\}\}/www\.topcoder\.com/g" dist/sites-enabled/*conf
else
	perl -pi -e "s/\{\{ENV_TLD\}\}/topcoder\.com/g" dist/sites-enabled/*conf
	perl -pi -e "s/\{\{ENV_TLD\}\}/topcoder\.com/g" dist/includes/*conf
	perl -pi -e "s/\{\{ENV_WWWTC\}\}/www\.topcoder\.com/g" dist/sites-enabled/*conf
fi

perl -pi -e "s/\{\{ENV_LOGIN_SUBDOMAIN_PREFIX\}\}/accounts-auth0/g" dist/sites-enabled/*conf
perl -pi -e "s/\{\{ENV\}\}/$ENV/g" dist/sites-enabled/*conf
perl -pi -e "s/\{\{ENV\}\}/$ENV/g" dist/includes/*conf
perl -pi -e "s/\{\{ENV_PLATFORM_UI_RESOLVER\}\}/$ENV_PLATFORM_UI_RESOLVER/g" dist/includes/*conf

#/root/init_logentries.sh (need to look in image)

if [[ "$PROVIDER" == local ]]; then
	docker build --no-cache -t nginx-supply:latest .
else
	# configure_aws_cli
	# aws s3 cp "s3://appirio-platform-$ENV/services/common/dockercfg" ~/.dockercfg
	#eval $(aws ecr get-login --region $AWS_REGION --no-include-email)
	# Builds Docker image of the app.
	# TAG=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$AWS_REPOSITORY:$CIRCLE_SHA1
	TAG=nginx-supply:latest
	SOURCE_COMMIT="${CIRCLE_SHA1:-local}"
	docker build --provenance=false --build-arg "SOURCE_COMMIT=${SOURCE_COMMIT}" -f ECSDockerfile -t "$TAG" .
fi
