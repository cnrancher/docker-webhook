#!/bin/bash  

CONFIG=${CONFIG:-/etc/webhook/hooks.json}

if [[ $MAIL_CACERT && ! -z $MAIL_CACERT ]]; then

    echo $MAIL_CACERT | base64 -d > /root/cacert.pem
fi

bash /monitoring.sh &

webhook -verbose -hooks=${CONFIG} -hotreload ${WEBHOOK_CMD}
