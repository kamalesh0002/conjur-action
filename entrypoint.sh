#!/bin/bash
# Conjur Secret Retrieval for GitHub Action conjur-action

main() {
    create_pem
    conjur_authn
    # Secrets Example: db/sqlusername | sql_username; db/sql_password
    array_secrets
    set_secrets
}

urlencode() {
    # urlencode <string>
    old_lc_collate=$LC_COLLATE
    LC_COLLATE=C

    local length="${#1}"
    for (( i = 0; i < length; i++ )); do
        local c="${1:i:1}"
        case $c in
            [a-zA-Z0-9.~_-]) printf "$c" ;;
            ' ') printf "%%20" ;;
            *) printf '%%%02X' "'$c" ;;
        esac
    done

    LC_COLLATE=$old_lc_collate
}

create_pem() {
    # Create conjur_account.pem for valid SSL
    echo "$INPUT_CERTIFICATE" > conjur_"$INPUT_ACCOUNT".pem
}

conjur_authn() {

	if [[ -n "$INPUT_AUTHN_ID" ]]; then

		echo "::debug Authenticate via Authn-JWT"
		JWT_TOKEN=$(curl -k -H "Authorization:bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL" | jq -r .value )
        
		if [[ -n "$INPUT_CERTIFICATE" ]]; then
            echo "::debug Authenticating with certificate"
			token=$(curl -k --cacert "conjur_$INPUT_ACCOUNT.pem" --request POST "$INPUT_URL/authn-jwt/$INPUT_AUTHN_ID/$INPUT_ACCOUNT/authenticate" --header "Content-Type: application/x-www-form-urlencoded" --header "Accept-Encoding: base64" --data-urlencode "jwt=$JWT_TOKEN")
		else
            echo "::debug Authenticating without certificate"
			token=$(curl -k --request POST "$INPUT_URL/authn-jwt/$INPUT_AUTHN_ID/$INPUT_ACCOUNT/authenticate" --header 'Content-Type: application/x-www-form-urlencoded' --header "Accept-Encoding: base64" --data-urlencode "jwt=$JWT_TOKEN")
		fi

	else
		echo "::debug Authenticate using Host ID & API Key"

        # URL-encode Host ID for future use
        hostId=$(urlencode "$INPUT_HOST_ID")

		if [[ -n "$INPUT_CERTIFICATE" ]]; then
			# Authenticate and receive session token from Conjur - encode Base64
			echo "::debug Authenticating with certificate"
            token=$(curl -k --cacert "conjur_$INPUT_ACCOUNT.pem" --data "$INPUT_API_KEY" "$INPUT_URL/authn/$INPUT_ACCOUNT/$hostId/authenticate" --header "Content-Type: application/x-www-form-urlencoded" --header "Accept-Encoding: base64")
		else
			# Authenticate and receive session token from Conjur - encode Base64
            echo "::debug Authenticating without certificate"
			token=$(curl -k --request POST --data "$INPUT_API_KEY" "$INPUT_URL/authn/$INPUT_ACCOUNT/$hostId/authenticate" --header "Content-Type: application/x-www-form-urlencoded" --header "Accept-Encoding: base64")
		fi
	fi
}

array_secrets() {
    IFS=';'
    read -ra SECRETS <<< "$INPUT_SECRETS" # [0]=db/sqlusername | sql_username [1]=db/sql_password
}

set_secrets() {
  if [[ ${SECRETS[@]} ]]; then
    for secret in "${SECRETS[@]}"; do
        IFS='|'
        read -ra METADATA <<< "$secret" # [0]=db/sqlusername [1]=sql_username

        if [[ "${#METADATA[@]}" == 2 ]]; then
            secretId=$(urlencode "${METADATA[0]}")
            envVar=${METADATA[1]^^}
        else
            secretId=${METADATA[0]}
            IFS='/'
            read -ra SPLITSECRET <<< "$secretId" # [0]=db [1]=sql_password
            arrLength=${#SPLITSECRET[@]} # Get array length
            lastIndex=$((arrLength-1)) # Subtract one for last index
            envVar=${SPLITSECRET[$lastIndex]^^}
            secretId=$(urlencode "${METADATA[0]}")
        fi
        
        if [[ -n "$INPUT_CERTIFICATE" ]]; then
            echo "::debug Retrieving secret with certificate"
            secretVal=$(curl -k --cacert "conjur_$INPUT_ACCOUNT.pem" -H "Authorization: Token token=\"$token\"" "$INPUT_URL/secrets/$INPUT_ACCOUNT/variable/$secretId")
        else
            echo "::debug Retrieving secret without certificate"
            secretVal=$(curl -k -H "Authorization: Token token=\"$token\"" "$INPUT_URL/secrets/$INPUT_ACCOUNT/variable/$secretId")
        fi

        if [[ "${secretVal}" == "Malformed authorization token" ]]; then
            echo "::error::Malformed authorization token. Please check your Conjur account, username, and API key. If using authn-jwt, check your Host ID annotations are correct."
            exit 1
	elif [[ "${secretVal}" == *"is empty or not found"* ]]; then
	    echo "::error::${secretVal}"
	    exit 1
        fi
        echo ::add-mask::"${secretVal}" # Masks the value in all logs & output
        echo "${envVar}=${secretVal}" >> "${GITHUB_ENV}" # Set environment variable
    done
  else 
   echo "::error::No secret found for retrieval from Conjur Vault"
  fi
}

main "$@"
