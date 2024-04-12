#!/bin/bash
# init arena config; creates root secrets and derives tokens for services; 
# creates config files from templates conf-templates -> conf
#
# NOTE: usually, this script should not be called directly; it is instead called from init.sh
#
# uses variables in .env and the following:
#   ALWAYS_YES="true" indicates that we answer yes to all questions: create new secrets, tokens, regenerate config files

# load utils
source init-utils/bash-common-utils.sh 

if [ "$(id -u)" -ne 0 ]; then echo "Not running as root. Please run init.sh instead." >&2; exit 1; fi

if [ -z "$CONFIG_FILES_ONLY" ]; then 

    echocolor ${HIGHLIGHT} "### Creating data folders."
    data_folders=( "data/arena-store" "data/grafana"  "data/mongodb"  "data/prometheus" "data/account" "data/keys")
    [ ! -d "data" ] && mkdir data
    for d in "${data_folders[@]}"
    do
      echo $d
      [ ! -d "$d" ] && mkdir $d && chown $OWNER $d
    done

    [ ! -d "conf/arena-web-conf" ] && mkdir conf/arena-web-conf && chown $OWNER conf/arena-web-conf

    echo "Done creating data folders."

    echocolor ${HIGHLIGHT} "### Creating secrets (in secret.env). This will replace old secret.env (if exists; backup will be in secret.env.bak)."
    readprompt "Create secret.env ? (y/N) "
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      SECRET_KEY=$(LC_ALL=C tr -dc '[:alnum:]' < /dev/urandom | head -c40)
      SECRET_KEY_BASE64=$(echo $SECRET_KEY | base64)
      cp secret.env secret.env.bak
      echo "SECRET_KEY=$SECRET_KEY" > secret.env
      echo "SECRET_KEY_BASE64=$SECRET_KEY_BASE64" >> secret.env
      echo "DJANGO_SUPERUSER_PASSWORD=$(LC_ALL=C tr -dc '[:alnum:]' < /dev/urandom | head -c15)" >> secret.env
      echo "STORE_ADMIN_PASSWORD=$(LC_ALL=C tr -dc '[:alnum:]' < /dev/urandom | head -c15)" >> secret.env
      [ -f secret.env ] && [[ $(wc -l <secret.env) -ge 4 ]] && echo "Done creating secrets." || echoerr "File secret.env not found or too few lines in secrets.env."
    fi

    echocolor ${HIGHLIGHT} "### Creating RSA key pair for JWT (conf/keys/jwt.priv.pem). This will replace old keys (if exist; backup will be in data/keys/jwt.priv.pem.bak)."
    readprompt "Create RSA key pair ? (y/N) "
    if [[ $REPLY =~ ^[Yy]$ ]]; then 
      [ -f ./data/keys/jwt.priv.pem ] && cp ./data/keys/jwt.priv.pem data/keys/jwt.priv.pem.bak
      rm ./data/keys/*
      openssl genrsa -out ./data/keys/jwt.priv.pem 4096 && \
      openssl rsa -in ./data/keys/jwt.priv.pem -pubout -outform PEM -out ./data/keys/jwt.public.pem && \
      openssl rsa -in ./data/keys/jwt.priv.pem -RSAPublicKey_out -outform DER -out ./data/keys/jwt.public.der # mqtt auth plugin requires RSAPublicKey format
      if [[ ! $? -eq 0 ]]; then 
        echoerr "Failure creating keys."
        exit 1
      fi
    fi

    # reset ownership of public keys
    [ -f ./data/keys/jwt.public.pem ] && chown $OWNER ./data/keys/jwt.public.pem
    [ -f ./data/keys/jwt.public.der ] && chown $OWNER ./data/keys/jwt.public.der

    rm ./conf/arena-web-conf/*.pem 2>/dev/null
    # copy public key to /conf/sha256(hostname).pem to be used for Atlassian Service Authentication Protocol (ASAP)
    HOSTSHA256=$(echo -n $HOSTNAME | shasum -a 256)
    cat ./data/keys/jwt.public.pem > ./conf/arena-web-conf/${HOSTSHA256%???}.pem

    echocolor ${HIGHLIGHT} "### Creating Service Tokens. This will replace service tokens in secret.env (if exists; backup will be in secret.env.bak)."
    readprompt "Create Service Tokens ? (y/N) "
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      grep -v '^SERVICE_' secret.env > secret.tmp # remove all service tokens
      cp secret.env secret.env.bak
      cp secret.tmp secret.env
      services=("arena_persist" "arena_arts" "py_runtime" "mqttbr")
      for s in "${services[@]}"
      do
        tn="SERVICE_${s^^}_JWT"
        echo "$tn=$(python /utils/genjwt.py -i $HOSTNAME -k ./data/keys/jwt.priv.pem $s)" >> secret.env
      done
      # generate a token for cli tools (for developers) and announce it in slack
      cli_token_json=$(python /utils/genjwt.py -i $HOSTNAME -k ./data/keys/jwt.priv.pem -j cli)
      echo $cli_token_json > ./data/keys/cli_token.json
      if [[ ! -z "$SLACK_DEV_CHANNEL_WEBHOOK" ]]; then
        username=$(echo $cli_token_json | python3 -c "import sys, json; print(json.load(sys.stdin)['username'])")
        cli_token=$(echo $cli_token_json | python3 -c "import sys, json; print(json.load(sys.stdin)['token'])")
        alias_name="${HOSTNAME%%.*}"
        curl_data="{\"text\":\"New MQTT token for $HOSTNAME\", \"attachments\": [ {\"text\":\"\`\`\`alias ${alias_name}_pub='mosquitto_pub -h $HOSTNAME -p 8883 -u $username -P $cli_token'\`\`\`\"}, {\"text\":\"\`\`\`alias ${alias_name}_sub='mosquitto_sub -h $HOSTNAME -p 8883 -u $username -P $cli_token'\`\`\`\"} ]}"
        curl -X POST -H 'Content-type: application/json' --data "$curl_data" $SLACK_DEV_CHANNEL_WEBHOOK
      fi

      # NOTE: check for errors by looking at number of lines in secret.env
      if [[ $(wc -l <secret.env) -ge 8 ]]; then 
        echo -e "Service tokens created.\n"
      else
        echoerr "Too few lines in secret.env."; 
        exit 1
      fi
    fi

fi # CONFIG_FILES_ONLY

# load secrets
export $(grep -v '^#' secret.env | xargs)

if [ -z "$CONFIG_FILES_ONLY" ]; then 

    if [ "$STORE_TMP_PORT" == "none" ]
    then
        echocolor ${HIGHLIGHT} "### Skipping filestore share and hash setup (instance failed to start)."
    else
        echocolor ${HIGHLIGHT} "### Generating filestore public share and inline js hash."
        readprompt "Create a public share on filebrowser ? (y/N) "
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            [ ! -d "store/public" ] && mkdir store/public
            fsauth_data='{"username": "'"$STORE_ADMIN_USERNAME"'", "password": "'"$STORE_ADMIN_PASSWORD"'"}'
            fsauth_token=$(curl -X POST -d "$fsauth_data" -H "Content-Type: application/json" "http://host.docker.internal:$STORE_TMP_PORT/api/login")

            # get share
            export FS_SHARE_HASH=$(curl -X GET -d "{}" -H "Content-Type: application/json" -H "X-Auth: $fsauth_token" "http://localhost:$STORE_TMP_PORT/api/share/public/" )
            if [ "$FS_SHARE_HASH" == "[]" ]
            then
                # create share
                export FS_SHARE_HASH=$(curl -X POST -d "{}" -H "Content-Type: application/json" -H "X-Auth: $fsauth_token" "http://localhost:$STORE_TMP_PORT/api/share/public/" | \
                    python3 -c "import sys, json; print(json.load(sys.stdin)['hash'])")
                echo "Share created: $FS_SHARE_HASH"
            else
                    echo "Share already exists: $FS_SHARE_HASH"
            fi
        fi

        # gen hash of filebrowser javascript launch script for CSP
        export FS_LAUNCH_JS_HASH=$(node ./init-utils/filebrowserScriptToHash.js http://host.docker.internal:$STORE_TMP_PORT)
        if [ -z "$FS_LAUNCH_JS_HASH" ]; then 
            echocolor ${WARNING} "No filestore hash created." 
        else   
            echo "New filestore hash: FS_LAUNCH_JS_HASH=$FS_LAUNCH_JS_HASH"
        fi
    fi

fi # CONFIG_FILES_ONLY

echocolor ${HIGHLIGHT} "### Creating config files (conf/*) from templates (conf-templates/*) and .env."
echocolor ${BOLD} "Backups will be created in conf/. Please edit the file .env to reflect your setup (hostname, jisti host, ...)."
echo 

# setup escape var for envsubst templates
export ESC="$"

# create a list of hostnames for python config files
HOSTNAMES_LIST=""
for host in $(echo "$HOSTNAME $ADDITIONAL_HOSTNAMES"|tr ' ' '\n'); do
  HOSTNAMES_LIST="$HOSTNAMES_LIST '$host',"
done
export HOSTNAMES_LIST=${HOSTNAMES_LIST::-1} # remove last comma

for fn in $(find conf-templates -type f)
do
  t="${fn/conf-templates/conf}" # conf-templates -> conf
  e="${fn##*.}" # save extension
  f="${t/.tmpl/}" # remove .tmpl extension
  d="$(dirname $t)" # get folder 
  # skip mac os files and .md files
  if [[ "$e" == "md" ]] || [[ "$e" == "DS_Store" ]]; then continue; fi
  echo -e "\t $fn -> $f"
  mkdir -p $d && chown $OWNER $d # create destinatinon folder if needed
  cp $f $f.bak >/dev/null 2>&1
  # do substitution on tmpl files; copy other files
  if [[ "$e" == "tmpl" ]]; then
    envsubst < $fn > $f
  else
    cp $fn $f
  fi
  chown $OWNER $f
done

# convert js config to json
for t in $(find ./conf -name "*.js" -type f)
do
    f="${t%.*}" # remove trailing ".js"
    node /utils/jsDefaultsToJson.js "$PWD/$t" > $f.json
    chown $OWNER $f.json
done

# copy arena-web-config files (config common to all setups) to each setup folder
setup_folders=("conf/localdev" "conf/prod" "conf/staging" "conf/demo")
for sf in "${setup_folders[@]}"
do
  if [ -d $sf ]; then
    wsf="$s/arena-web-conf"
    # todo: this will overwrite files existing in destination (setup folder)
    cp conf/arena-web-conf/* $sf/arena-web-conf/
  else
    echocolor ${WARNING} "Setup folder $sf not found; skipping."
  fi 
done

[ -d conf ] && [[ $(ls conf/* | wc -l) -ge 20 ]] && echo "Config files created.\n" || echoerr "Folder conf/ not found or too few config files found."

# TODO: Re-enable additions hostnames - They are not allowing certbot to renew certificates
# add server block to redirect additional hostnames
# if [[ ! -z "$ADDITIONAL_HOSTNAMES" ]]; then
#         TMPFN=/tmp/nginx_tmpcfg
#         cat > $TMPFN <<  EOF

# server {
#     server_name         $ADDITIONAL_HOSTNAMES;
#     server_tokens off;
#     client_max_body_size 1000M;

#     listen              443 ssl;
#     ssl_certificate     /etc/letsencrypt/live/arenaxr.org/fullchain.pem;
#     ssl_certificate_key /etc/letsencrypt/live/arenaxr.org/privkey.pem;
#     include             /etc/letsencrypt/options-ssl-nginx.conf;
#     ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

#     location ^~ /user/ {
#         add_header 'Access-Control-Allow-Origin' "\$http_origin";
#         add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, DELETE, PUT';
#         add_header 'Access-Control-Allow-Credentials' 'true';
#         add_header 'Access-Control-Allow-Headers' 'User-Agent,Keep-Alive,Content-Type';
#         proxy_pass http://arena-account:8000;
#         proxy_http_version 1.1;
#         proxy_set_header Host $host;
#         proxy_set_header Upgrade \$http_upgrade;
#         proxy_set_header Connection "Upgrade";
#         proxy_read_timeout 86400;
#     }

#     location / {
#         return 301 https://$HOSTNAME\$request_uri;
#     }
# }
# EOF
#         # add server block to production and staging
#         cat $TMPFN >> ./conf/arena-web.conf
#         cat $TMPFN >> ./conf/arena-web-staging.conf
#         rm $TMPFN
# fi

