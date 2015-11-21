#!/bin/bash
EVM=$ENV
if [[ -z "$EVM" ]] ; then
	echo "Environment should be set on startup with one of the below values"
	echo "ENV must be one of - dev, qa, prod or local"
	exit
fi

rm -rf dist
mkdir dist
mkdir dist/sites-enabled
mkdir dist/includes

# copy know conf folders
cp src/sites-enabled/*conf dist/sites-enabled/
cp src/includes/*conf dist/includes/
cp src/*conf dist/

if [[ "$EVM" == dev ]]; then
	cp -R src/dev dist/
fi

if [[ "$EVM" == local ]]; then
	cp -R src/local /data/nginx
fi

if [[ "$EVM" != prod ]]; then
	perl -pi -e "s/\{\{ENV_TLD\}\}/topcoder-$EVM\.com/g" dist/sites-enabled/*conf
else
	perl -pi -e "s/\{\{ENV_TLD\}\}/topcoder\.com/g" dist/sites-enabled/*conf
fi

perl -pi -e "s/\{\{EVM\}\}/$EVM/g" dist/sites-enabled/*conf