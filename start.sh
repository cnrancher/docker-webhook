#!/bin/bash  

CONFIG=${CONFIG:-/etc/webhook/hooks.json}

bash /monitoring.sh  &

webhook -verbose -hooks=${CONFIG} -hotreload ${WEBHOOK_CMD}
