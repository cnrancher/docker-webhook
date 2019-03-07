#!/bin/bash  

bash /monitoring.sh  &

webhook -verbose -hooks=/etc/webhook/hooks.json -hotreload $WEBHOOK_
