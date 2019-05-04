#!/bin/bash

DATA_SOURCD=$1
APP_NS=$( echo $APP_NS | tr 'A-Z' 'a-z' )
APP_WORKLOAD=$( echo $APP_WORKLOAD | tr 'A-Z' 'a-z' )
APP_CONTAINER=$( echo $APP_CONTAINER | tr 'A-Z' 'a-z' )
REPO_TYPE=$( echo $REPO_TYPE | tr 'A-Z' 'a-z' )
NET_TYPE=$( echo $NET_TYPE | tr 'A-Z' 'a-z' )
MAIL_TO=$( echo $MAIL_TO | tr 'A-Z' 'a-z' )

MAIL_FROM=$( echo $MAIL_FROM | tr 'A-Z' 'a-z' )
MAIL_PASSWORD=$( echo $MAIL_PASSWORD | base64 -d )
MAIL_SMTP_SERVER=$( echo $MAIL_SMTP_SERVER | tr 'A-Z' 'a-z' )
MAIL_SMTP_PORT=$MAIL_SMTP_PORT
MAIL_CACERT=$MAIL_CACERT
MAIL_TLS_CHECK=${MAIL_TLS_CHECK:-true}

# 发送通知邮件

send_mail ()
{
cat << EOF > mail.txt
From: $MAIL_FROM
To: $MAIL_TO
Subject: Webhooks通知: $APP_NS-$APP_WORKLOAD-$APP_CONTAINER 更新结果
Date: $( date -Iseconds )

更新容器: $APP_CONTAINER
升级前镜像: $OLD_IMAGES
升级后镜像: $IMAGES

操作结果: `cat $APP_NS-$APP_CONTAINER`
应用状态:

EOF
    sleep 10
 
    kubectl -n $APP_NS get pod | grep `echo $APP_WORKLOAD | awk -F/ '{print $2}'` | awk '{print $1}' | xargs kubectl -n $APP_NS describe pod >> mail.txt

    if [[ $MAIL_TLS_CHECK && $MAIL_TLS_CHECK == 'true' ]]; then
        curl --silent --ssl --url "smtps://$MAIL_SMTP_SERVER:$MAIL_SMTP_PORT" \
        --mail-from "$MAIL_FROM" --mail-rcpt "$MAIL_TO" \
        --user "$MAIL_FROM:$MAIL_PASSWORD" \
        --upload-file mail.txt

        return
    fi

    if [[ $MAIL_CACERT && ! -z $MAIL_CACERT && $MAIL_TLS_CHECK == 'true' ]]; then
        curl --silent --ssl --url "smtps://$MAIL_SMTP_SERVER:$MAIL_SMTP_PORT" \
        --mail-from "$MAIL_FROM" --mail-rcpt "$MAIL_TO" \
        --cacert=/root/cacert.pem \
        --user "$MAIL_FROM:$MAIL_PASSWORD" \
        --upload-file mail.txt

        return
    fi

    if [[ $MAIL_TLS_CHECK && $MAIL_TLS_CHECK == 'false' ]]; then
        curl --silent --url "smtps://$MAIL_SMTP_SERVER:$MAIL_SMTP_PORT" \
        --mail-from "$MAIL_FROM" --mail-rcpt "$MAIL_TO" \
        --user "$MAIL_FROM:$MAIL_PASSWORD" \
        --insecure \
        --upload-file mail.txt

        return
    fi
}

# 检查是否为测试消息。dockerhub在添加webhooks条目时会触发测试webhooks消息，以下判断排除此消息。

if [[ $( echo $DATA_SOURCD | jq '.push_data | has("tag")' ) == 'true' && $( echo $DATA_SOURCD | jq '.repository | has("name")' ) == 'true' && $( echo $DATA_SOURCD | jq '.repository | has("namespace")' ) == 'true' ]]; then

    # 判断是否存在升级的容器

    if kubectl -n $APP_NS get $APP_WORKLOAD -o json | jq -cr '.spec.template.spec.containers[].name' | grep -qiE $APP_CONTAINER ; then  
        echo "开始升级$APP_CONTAINER容器"
    else
        echo "没有容器：$APP_CONTAINER，请检查配置"
        exit 1
    fi

    OLD_IMAGES=$( kubectl -n $APP_NS get $APP_WORKLOAD -o json | jq -r ".spec.template.spec.containers[] | select(.name == \"$APP_CONTAINER\") | .image" )

    # 判断仓库类型

    # Aliyun
    if echo $REPO_TYPE | grep -qwi "aliyun" ; then

        echo "当前仓库类型为 $REPO_TYPE" 
        echo "当前仓库网络类型为 $NET_TYPE" 

        IMAGES_TAG=$( echo $DATA_SOURCD | jq -r '.push_data.tag' )
        REPO_NAME=$( echo $DATA_SOURCD | jq -r '.repository.name' )
        REPO_NS=$( echo $DATA_SOURCD | jq -r '.repository.namespace')
        REPO_REGION=$( echo $DATA_SOURCD | jq -r '.repository.region' )
        REPO_FULL_NAME=$( echo $DATA_SOURCD | jq -r '.repository.repo_full_name' )

        if [[ x"${NET_TYPE}" == x"vpc" ]]; then

            IMAGES=$( echo "registry-vpc.$REPO_REGION.aliyuncs.com/$REPO_FULL_NAME:$IMAGES_TAG" )
        elif [[ x"${NET_TYPE}" == x"internal" ]]; then

            IMAGES=$( echo "registry-internal.$REPO_REGION.aliyuncs.com/$REPO_FULL_NAME:$IMAGES_TAG" )
        else

            IMAGES=$( echo "registry.$REPO_REGION.aliyuncs.com/$REPO_FULL_NAME:$IMAGES_TAG" )
        fi

        # 如果镜像标签有改变，则直接通过kubectl set进行升级

        if [[ x"${IMAGES}" != x"$OLD_IMAGES" ]]; then

            echo "镜像有变化，通过kubectl set进行升级"

            kubectl -n $APP_NS set image $APP_WORKLOAD $APP_CONTAINER=$IMAGES --record 2>&1 | tee $APP_NS-$APP_CONTAINER

            if [[ $MAIL_FROM != '' && $MAIL_TO != '' ]]; then
                send_mail
            fi

            exit $?
        else
        	
            # 如果镜像标签没有改变，则检查镜像拉取策略，需要设置镜像拉取策略为Always才能触发重新拉取镜像。
            # 如果镜像拉取策略是Always，则在.spec.template.metadata.annotations中添加注释用来触发滚动更新。

            echo "镜像未改变，添加注释进行滚动升级"
 
            kubectl -n $APP_NS get $APP_WORKLOAD -o json | \
            jq '.spec.template.spec.containers[] | select(.name == "$APP_CONTAINER") += {"imagePullPolicy": "Always"}' | \
            jq --arg time $( date -Iseconds ) '.spec.template.metadata.annotations += {"webhooks/updateTimestamp": $time}' | \
            kubectl -n $APP_NS apply -f - 2>&1 | tee $APP_NS-$APP_CONTAINER

            if [[ $MAIL_FROM != '' && $MAIL_TO != '' ]] ; then
                send_mail
            fi
            exit $?
        fi
    fi

    # Docker HUB

    if echo $REPO_TYPE | grep -qwi "dockerhub" ; then

        echo "当前仓库类型为 $REPO_TYPE"

        IMAGES_TAG=$( echo $DATA_SOURCD | jq -r '.push_data.tag' )
        REPO_NAME=$( echo $DATA_SOURCD | jq -r '.repository.name' )
        REPO_NS=$( echo $DATA_SOURCD | jq -r '.repository.namespace' )
        REPO_FULL_NAME=$( echo $DATA_SOURCD | jq -r '.repository.repo_name' )

        IMAGES=$( echo "$REPO_FULL_NAME/$IMAGES_TAG" )

        if [[ x"${IMAGES}" != x"$OLD_IMAGES" ]]; then

            echo "镜像有变化，通过kubectl set进行升级"

            kubectl -n $APP_NS set image $APP_WORKLOAD $APP_CONTAINER=$IMAGES --record 2>&1 | tee $APP_NS-$APP_CONTAINER

            if [[ $MAIL_FROM != '' && $MAIL_TO != '' ]] ; then
                send_mail
            fi

            exit $?
        else
        	
            # 如果镜像没有改变，则检查镜像拉取策略，需要设置镜像拉取策略为Always才能触发重新拉取镜像。
            # 如果镜像拉取策略是Always，则在.spec.template.metadata.annotations中添加注释用来触发滚动更新。

            echo "镜像未改变，添加注释进行滚动升级"
 
            kubectl -n $APP_NS get $APP_WORKLOAD -o json | \
            jq '.spec.template.spec.containers[] | select(.name == "$APP_CONTAINER") += {"imagePullPolicy": "Always"}' | \
            jq --arg time $( date -Iseconds ) '.spec.template.metadata.annotations += {"webhooks/updateTimestamp": $time}' | \
            kubectl -n $APP_NS apply -f - 2>&1 | tee $APP_NS-$APP_CONTAINER

            if [[ $MAIL_FROM != '' && $MAIL_TO != '' ]] ; then
                send_mail
            fi
            exit $?
        fi      
    fi

    # custom

    if echo $REPO_TYPE | grep -qwi "custom" ; then

        echo "当前镜像仓库为: $REPO_TYPE"

        IMAGES_URL=$( echo $DATA_SOURCD | jq -r '.repository.repo_url' )
        IMAGES_NS=$( echo $DATA_SOURCD | jq -r '.repository.namespace' )
        IMAGES_NAME=$( echo $DATA_SOURCD | jq -r '.repository.name' )
        IMAGES_TAG=$( echo $DATA_SOURCD | jq -r '.push_data.tag' )

        IMAGES=$( echo "$IMAGES_URL/$IMAGES_NS/$IMAGES_NAME:$IMAGES_TAG" )

        if [[ x"${IMAGES}" != x"$OLD_IMAGES" ]]; then

            echo "镜像有变化，通过kubectl set进行升级"
            
            kubectl -n $APP_NS set image $APP_WORKLOAD $APP_CONTAINER=$IMAGES --record 2>&1 | tee $APP_NS-$APP_CONTAINER

            if [[ $MAIL_FROM != '' && $MAIL_TO != '' ]] ; then
                send_mail
            fi

            exit $?
        else
        	
            # 如果镜像没有改变，则检查镜像拉取策略，需要设置镜像拉取策略为Always才能触发重新拉取镜像。
            # 如果镜像拉取策略是Always，则在.spec.template.metadata.annotations中添加注释用来触发滚动更新。

            echo "镜像未改变，添加注释进行滚动升级"
 
            kubectl -n $APP_NS get $APP_WORKLOAD -o json | \
            jq '.spec.template.spec.containers[] | select(.name == "$APP_CONTAINER") += {"imagePullPolicy": "Always"}' | \
            jq --arg time $( date -Iseconds ) '.spec.template.metadata.annotations += {"webhooks/updateTimestamp": $time}' | \
            kubectl -n $APP_NS apply -f - 2>&1 | tee $APP_NS-$APP_CONTAINER

            if [[ $MAIL_FROM != '' && $MAIL_TO != '' ]] ; then
                send_mail
            fi
            exit $?
        fi
    fi

    echo "$REPO_TYPE 为不支持的仓库类型"
    exit $?
fi