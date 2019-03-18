#!/bin/bash

DATA_SOURCD=$1
APP_NS=$( echo $APP_NS | tr 'A-Z' 'a-z' )
APP_WORKLOAD=$( echo $APP_WORKLOAD | tr 'A-Z' 'a-z' )
APP_CONTAINER=$( echo $APP_CONTAINER | tr 'A-Z' 'a-z' )
REPO_TYPE=$( echo $REPO_TYPE | tr 'A-Z' 'a-z' )
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
Subject: Webhooks通知: $APP_NS-$APP_WORKLOAD 更新结果
Date: $( date -Iseconds )

升级前镜像: $OLD_IMAGES
升级后镜像: $IMAGES

操作结果: `cat $APP_NS-$APP_CONTAINER`。
EOF

    if [[ $MAIL_TLS_CHECK && $MAIL_TLS_CHECK == 'true' ]]; then
        curl --ssl --url "smtps://$MAIL_SMTP_SERVER:$MAIL_SMTP_PORT" \
        --mail-from "$MAIL_FROM" --mail-rcpt "$MAIL_TO" \
        --user "$MAIL_FROM:$MAIL_PASSWORD" \
        --upload-file mail.txt

        return
    fi

    if [[ $MAIL_CACERT && ! -z $MAIL_CACERT && $MAIL_TLS_CHECK == 'true' ]]; then
        curl --ssl --url "smtps://$MAIL_SMTP_SERVER:$MAIL_SMTP_PORT" \
        --mail-from "$MAIL_FROM" --mail-rcpt "$MAIL_TO" \
        --cacert=/root/cacert.pem \
        --user "$MAIL_FROM:$MAIL_PASSWORD" \
        --upload-file mail.txt

        return
    fi

    if [[ $MAIL_TLS_CHECK && $MAIL_TLS_CHECK == 'false' ]]; then
        curl --url "smtps://$MAIL_SMTP_SERVER:$MAIL_SMTP_PORT" \
        --mail-from "$MAIL_FROM" --mail-rcpt "$MAIL_TO" \
        --user "$MAIL_FROM:$MAIL_PASSWORD" \
        --insecure \
        --upload-file mail.txt

        return
    fi
}

# 检查是否为测试消息。dockerhub在添加webhooks条目时会触发测试webhooks消息，以下判断排除此消息。
if [[ $( echo $DATA_SOURCD | jq '.push_data | has("tag")' ) == 'true' && $( echo $DATA_SOURCD | jq '.repository | has("name")' ) == 'true' && $( echo $DATA_SOURCD | jq '.repository | has("namespace")' ) == 'true' ]]; then

    # 判断仓库类型

    # Aliyunhub
    if echo $REPO_TYPE | grep -qwi "aliyun" ; then

        echo "当前仓库类型为 $REPO_TYPE"
        IMAGES_TAG=$( echo $DATA_SOURCD | jq -r '.push_data.tag' )
        REPO_NAME=$( echo $DATA_SOURCD | jq -r '.repository.name' )
        REPO_NS=$( echo $DATA_SOURCD | jq -r '.repository.namespace')
        REPO_REGION=$( echo $DATA_SOURCD | jq -r '.repository.region' )
        REPO_FULL_NAME=$( echo $DATA_SOURCD | jq -r '.repository.repo_full_name' )

        IMAGES=$( echo "registry.$REPO_REGION.aliyuncs.com/$REPO_FULL_NAME:$IMAGES_TAG" )
        OLD_IMAGES=$( kubectl -n $APP_NS get $APP_WORKLOAD -o json | jq -r '.spec.template.spec.containers[].image' )

        # 判断镜像标签是否为latest，如果不是latest则直接通过kubectl set进行升级。
        if [ x"${IMAGES_TAG}" != x"latest" ]; then

            echo "镜像标签不为latest,直接进行升级"
            kubectl -n $APP_NS set image $APP_WORKLOAD $APP_CONTAINER=$IMAGES --record 2>&1 | tee $APP_NS-$APP_CONTAINER

            if [[ $MAIL_FROM != '' && $MAIL_TO != '' ]] ; then
                send_mail
            fi

            exit $?
        else
            # 检查镜像拉取策略,对于镜像标签为latest的应用，需要设置镜像拉取策略为Always才能触发重新拉取镜像。
            echo "镜像标签为latest"
            IMAGES_PULL_POLICY=$( kubectl -n $APP_NS get $APP_WORKLOAD -o json | jq -r .spec.template.spec.containers[].imagePullPolicy )

            if [ x"${IMAGES_PULL_POLICY}" == x"Always" ]; then

                echo "镜像拉取策略为Always，添加注释触发滚动升级 "
                # 如果镜像拉取策略是Always，则在.spec.template.metadata.annotations中添加注释用来触发滚动更新。
                kubectl -n $APP_NS get $APP_WORKLOAD -o json | \
                jq --arg images $( echo $IMAGES ) '.spec.template.spec.containers[] += {"image": $images}' | \
                jq --arg time $( date -Iseconds ) '.spec.template.metadata.annotations += {"webhooks/updateTimestamp": $time}' | \
                kubectl -n $APP_NS apply -f - 2>&1 | tee $APP_NS-$APP_CONTAINER

                if [[ $MAIL_FROM != '' && $MAIL_TO != '' ]] ; then
                    send_mail
                fi

                exit $?

            else 
                # 如果镜像拉取策略不是Always，则先修改为Always，再在.spec.template.metadata.annotations中添加注释用来触发滚动更新。
                echo "镜像拉取策略不为Always。先替换为Always，再添加注释进行滚动升级 "
                kubectl -n $APP_NS get $APP_WORKLOAD -o json | \
                jq '.spec.template.spec.containers[] += {"imagePullPolicy": "Always"}' | \
                jq --arg images $( echo $IMAGES ) '.spec.template.spec.containers[] += {"image": $images}' | \
                jq --arg time $( date -Iseconds ) '.spec.template.metadata.annotations += {"webhooks/updateTimestamp": $time}' | \
                kubectl -n $APP_NS apply -f - 2>&1 | tee $APP_NS-$APP_CONTAINER

                if [[ $MAIL_FROM != '' && $MAIL_TO != '' ]] ; then
                    send_mail
                fi

                exit $?
            fi
        fi
    fi

    # Dockerhub
    if echo $REPO_TYPE | grep -qwi "dockerhub" ; then

        echo "当前仓库类型为 $REPO_TYPE"
        IMAGES_TAG=$( echo $DATA_SOURCD | jq -r '.push_data.tag' )
        REPO_NAME=$( echo $DATA_SOURCD | jq -r '.repository.name' )
        REPO_NS=$( echo $DATA_SOURCD | jq -r '.repository.namespace' )
        REPO_FULL_NAME=$( echo $DATA_SOURCD | jq -r '.repository.repo_name' )

        IMAGES=$( echo "$REPO_FULL_NAME/$IMAGES_TAG" )
        OLD_IMAGES=$( kubectl -n $APP_NS get $APP_WORKLOAD -o json | jq -r '.spec.template.spec.containers[].image' )

        if [ x"${IMAGES_TAG}" != x"latest" ]; then
            echo "镜像标签不为latest,直接进行升级"
            kubectl -n $APP_NS set image $APP_WORKLOAD $APP_CONTAINER=$IMAGES --record 2>&1 | tee $APP_NS-$APP_CONTAINER

            if [[ $MAIL_FROM != '' && $MAIL_TO != '' ]] ; then
                send_mail
            fi

            exit $?
        else
            echo "镜像标签为latest"
            IMAGES_PULL_POLICY=$( kubectl -n $APP_NS get $APP_WORKLOAD -o json | jq -r .spec.template.spec.containers[].imagePullPolicy )

            if [ x"${IMAGES_PULL_POLICY}" == x"Always" ]; then

                echo "镜像拉取策略为Always，添加注释进行滚动升级 "
                kubectl -n $APP_NS get $APP_WORKLOAD -o json | \
                jq --arg images $( echo $IMAGES ) '.spec.template.spec.containers[] += {"image": $images}' | \
                jq --arg time $( date -Iseconds ) '.spec.template.metadata.annotations += {"webhooks/updateTimestamp": $time}' | \
                kubectl -n $APP_NS apply  -f - 2>&1 | tee $APP_NS-$APP_CONTAINER

                if [[ $MAIL_FROM != '' && $MAIL_TO != '' ]] ; then
                    send_mail
                fi

                exit $?
            else
                echo "镜像拉取策略不为Always。先替换为Always，再添加注释进行滚动升级 "
                kubectl -n $APP_NS get $APP_WORKLOAD -o json | \
                jq --arg images $( echo $IMAGES ) '.spec.template.spec.containers[] += {"image": $images}' | \
                jq --arg time $( date -Iseconds ) '.spec.template.metadata.annotations += {"webhooks/updateTimestamp": $time}' | \
                jq '.spec.template.spec.containers[] += {"imagePullPolicy": "Always"}' | \
                kubectl -n $APP_NS apply  -f - 2>&1 | tee $APP_NS-$APP_CONTAINER

                if [[ $MAIL_FROM != '' && $MAIL_TO != '' ]] ; then
                    send_mail
                fi

                exit $?
            fi
        fi      
    fi

    # custom
    if echo $REPO_TYPE | grep -qwi "custom" ; then

        echo "当前仓库类型为 $REPO_TYPE"
        IMAGES_URL=$( echo $DATA_SOURCD | jq -r '.repository.repo_url' )
        IMAGES_NS=$( echo $DATA_SOURCD | jq -r '.repository.namespace' )
        IMAGES_NAME=$( echo $DATA_SOURCD | jq -r '.repository.name' )
        IMAGES_TAG=$( echo $DATA_SOURCD | jq -r '.push_data.tag' )

        IMAGES=$( echo "$IMAGES_URL/$IMAGES_NS/$IMAGES_NAME:$IMAGES_TAG" )
        OLD_IMAGES=$( kubectl -n $APP_NS get $APP_WORKLOAD -o json | jq -r '.spec.template.spec.containers[].image' )

        if [ x"${IMAGES_TAG}" != x"latest" ]; then
            echo "镜像标签不为latest,直接进行升级"
            kubectl -n $APP_NS set image $APP_WORKLOAD $APP_CONTAINER=$IMAGES --record 2>&1 | tee $APP_NS-$APP_CONTAINER

            if [[ $MAIL_FROM != '' && $MAIL_TO != '' ]] ; then
                send_mail
            fi

            exit $?
        else
            echo "镜像标签为latest"
            IMAGES_PULL_POLICY=$( kubectl -n $APP_NS get $APP_WORKLOAD -o json | jq -r .spec.template.spec.containers[].imagePullPolicy )

            if [ x"${IMAGES_PULL_POLICY}" == x"Always" ]; then

                echo "镜像拉取策略为Always，添加注释进行滚动升级 "
                kubectl -n $APP_NS get $APP_WORKLOAD -o json | \
                jq --arg images $( echo $IMAGES ) '.spec.template.spec.containers[] += {"image": $images}' | \
                jq --arg time $( date -Iseconds ) '.spec.template.metadata.annotations += {"webhooks/updateTimestamp": $time}' | \
                kubectl -n $APP_NS apply  -f - 2>&1 | tee $APP_NS-$APP_CONTAINER

                if [[ $MAIL_FROM != '' && $MAIL_TO != '' ]] ; then
                    send_mail
                fi

                exit $?
            else
                echo "镜像拉取策略不为Always。先替换为Always，再添加注释进行滚动升级 "
                kubectl -n $APP_NS get $APP_WORKLOAD -o json | \
                jq '.spec.template.spec.containers[] += {"imagePullPolicy": "Always"}' | \
                jq --arg images $( echo $IMAGES ) '.spec.template.spec.containers[] += {"image": $images}' | \
                jq --arg time $( date -Iseconds ) '.spec.template.metadata.annotations += {"webhooks/updateTimestamp": $time}' | \
                kubectl -n $APP_NS apply  -f - 2>&1 | tee $APP_NS-$APP_CONTAINER

                if [[ $MAIL_FROM != '' && $MAIL_TO != '' ]] ; then
                    send_mail
                fi

                exit $?
            fi
        fi      
    fi

    echo "$REPO_TYPE 为不支持的仓库类型"
    exit $?
fi