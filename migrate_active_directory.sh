#!/bin/bash

if [ -n "$DEBUG" ]
then
    set -x
fi

usage() {
    echo "./migrate_active_directory.sh [--insecure-skip-tls-verify]"
    echo "Migrates Rancher users from Active Directory to be based on GUID rather than Distinguished Name"
    echo "Requires kubectl, jq, and ldapsearch to be installed and available on \$PATH"
    echo "--insecure-skip-tls-verify can be set to configure the script to ignore tls verification"
    echo "RANCHER_TOKEN must be set with an admin token generated with no scope"
    echo "RANCHER_URL must be set with the url of rancher (no trailing /) - should be the server URL"
}

# decode_guid takes a base64 encoded objectGUID from ldapsearch
# It hex dumps and then orders the result according to the rules of GUID
function decode_guid(){
    encodedGuid=$1
    G=$(echo "$encodedGuid" | base64 -d | hexdump -e '16/1 " %02X"')
    orderedGuid="${G[3]}${G[2]}${G[1]}${G[0]}${G[5]}${G[4]}${G[7]}${G[6]}${G[8]}${G[9]}${G[10]}${G[11]}${G[12]}${G[13]}${G[14]}${G[15]}"
    echo "$orderedGuid" | tr '[:upper:]' '[:lower:]' | sed -e 's/ //g'
}

# swap_principal will replace the oldPrincipal with the newPrincipal on the given user's object
function swap_principal {
  user=$1
  newPrincipal=$2
  oldPrincipal=$3

  userJson=$(kubectl get user $user -o json)
  newJson=$(echo ${userJson/${oldPrincipal}/${newPrincipal}})
  result=$(echo $newJson | kubectl apply -f -)
}

# update_rb_for_user will get all of the rbType objects for the given oldPrincipal
# it will then create a new rbType with the principalId set to the passed-in principal
# the user parameter is only used to make the output more readable
function update_rb_for_user {
  echo "Migrating ${rbType} for $1"
  user=$1
  principal=$2
  oldPrincipal=$3
  rbType=$4

  #TODO REMOVE for testing
  oldPrincipal="activedirectory_user://bfb34c007dc2c843adcc74ac3e27df21"

  rbs=$(kubectl get "${rbType}" -A -o jsonpath='{range .items[?(@.userPrincipalName=="'${oldPrincipal}'")]}{.metadata.namespace}|{.metadata.name}{"\n"}{end}')
  for rb in $rbs
  do
    rbNamespace=$(echo ${rb} |cut -d '|' -f1)
    rbName=$(echo ${rb} |cut -d '|' -f2)
    echo "Updating ${rbType} for ${user} Namespace: $rbNamespace  Name: $rbName"
    rbJson=$(kubectl get ${rbType} -n ${rbNamespace} ${rbName} -o json)
    newRbJson=$(echo ${rbJson/${oldPrincipal}/${principal}})
    newRbJson=$(echo ${newRbJson/\"name\": \"${rbName}\"/\"name\": \"\"})
    result=$(echo $newRbJson | kubectl create -f -)
    echo $result
    deleteResult=$(kubectl delete ${rbType} -n ${rbNamespace} ${rbName})
    echo $deleteResult
  done
}

function update_token_for_user {
  user=$1
  principal=$2
  oldPrincipal=$3

  #TODO REMOVE for testing
  oldPrincipal="activedirectory_user://bfb34c007dc2c843adcc74ac3e27df21"

  tokens=$(kubectl get tokens -o jsonpath='{range .items[?(@.userPrincipal.metadata.name=="'${oldPrincipal}'")]}{.metadata.name}{"\n"}{end}')
  for tokenName in $tokens
  do
    echo "Updating token for $user Token:${tokenName}"
    tokenJson=$(kubectl get token "${tokenName}" -o json)
    newTokenJson=$(echo ${tokenJson/${oldPrincipal}/${principal}})
    result=$(echo $newTokenJson | kubectl apply -f -)
    echo $result
  done
}

function migrate_ad_user {
  echo "migrating $1 $2"
  user=$1
  principal=$2
  oldPrincipal=$3

  principalParts=(${principal//:\/\// })
  ldapGuid=$(ldapsearch -x -H  "ldap://$adServer" -D "$serviceUser" -w $servicePass -b ${principalParts[1]} '(&(objectClass=person))' | grep "objectGUID")
  ldapGuidParts=($ldapGuid)
  decodedGuid=$(decode_guid ${ldapGuidParts[1]})
  #TODO REMOVE for testing
  #swap_principal $user $decodedGuid $oldPrincipal
  update_rb_for_user $user "activedirectory_user://${decodedGuid}" $oldPrincipal "clusterroletemplatebinding"
  update_rb_for_user $user "activedirectory_user://${decodedGuid}" $oldPrincipal "projectroletemplatebinding"
  update_token_for_user $user "activedirectory_user://${decodedGuid}" $oldPrincipal
}


function check_and_migrate_ad_user {
  user=$1
  principalString=$2
  echo "check and migrate user $user"

  # split on ://
  idParts=(${principalString//:\/\// })
  # compare lower-cased versions of strings with ,,
  # If the principal ends with the userSearchBase, it's a principal based on DN
  if [[ ${idParts[1],,} == *${userSearchBase,,} ]]; then
        echo "$user - $principal is an old-style principal"
        migrate_ad_user $user $principal ${idParts[1]}
  else
        echo "$principal is not an old-style principal, skipping"
  fi
}

# get_secret_data looks-up and returns the password for the AD SA
function get_secret_data {
  secretLocation=$1
  secretParts=(${secretLocation//:/ })
  echo $(kubectl get secret -n ${secretParts[0]} ${secretParts[1]} --template={{.data.serviceaccountpassword}} | base64 -d)
}

if [[ -z "$RANCHER_TOKEN" || -z "$RANCHER_URL" ]]
then
	echo "Env vars not properly set"
	usage
	exit 1
fi

tlsVerify="$1"

kubeconfig="
apiVersion: v1
kind: Config
clusters:
- name: \"local\"
  cluster:
    server: \"$RANCHER_URL\"
users:
- name: \"local\"
  user:
    token: \"$RANCHER_TOKEN\"
contexts:
- name: \"local\"
  context:
    user: \"local\"
    cluster: \"local\"
current-context: \"local\"
"

echo "$kubeconfig" >> .temp_kubeconfig.yaml
chmod g-r .temp_kubeconfig.yaml
chmod o-r .temp_kubeconfig.yaml
export KUBECONFIG="$(pwd)/.temp_kubeconfig.yaml"

if [[ "$tlsVerify" != "" ]]
then
	kubectl config set clusters.local.insecure-skip-tls-verify true
fi

adServer=$(kubectl get authconfig activedirectory -o jsonpath="{.servers[0]}")
userSearchBase=$(kubectl get authconfig activedirectory -o jsonpath="{.userSearchBase}")
serviceUser=$(kubectl get authconfig activedirectory -o jsonpath="{.serviceAccountUsername}")
servicePassSecret=$(kubectl get authconfig activedirectory -o jsonpath="{.serviceAccountPassword}")
servicePass=$(get_secret_data ${servicePassSecret})

users=$(kubectl get users -o jsonpath="{.items[*].metadata.name}")
for user in $users
do
  principalIds=$(kubectl get user $user -o jsonpath="{.principalIds}"  | jq -r -c '.[]')
  for principal in $principalIds
  do
    if [[ $principal == activedirectory_user* ]]; then
      check_and_migrate_ad_user $user $principal
    fi
  done
done

rm .temp_kubeconfig.yaml
exit 0
