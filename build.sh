#!/bin/bash

if [[ -z "$ENV" ]] ; then
	echo "Environment should be set on startup with one of the below values"
	echo "ENV must be one of - dev, qa, prod or local"
	exit
fi

if [[ "$ENV" == dev ]]; then
	cp -R /data/nginx/dev /data/nginx/
fi

if [[ "$ENV" == local ]]; then
	cp -rf /data/nginx/local/includes/*.conf /data/nginx/includes/
fi

if [[ "$ENV" != prod ]]; then
	perl -pi -e "s/\{\{ENV_TLD\}\}/topcoder-$ENV\.com/g" /data/nginx/sites-enabled/*conf
else
	perl -pi -e "s/\{\{ENV_TLD\}\}/topcoder\.com/g" /data/nginx/sites-enabled/*conf
fi

perl -pi -e "s/\{\{ENV\}\}/$ENV/g" /data/nginx/sites-enabled/*conf