load_pubkey() {
  local private_key_path=$TMPDIR/git-resource-private-key

  (jq -r '.source.private_key // empty' < $1) > $private_key_path

  if [ -s $private_key_path ]; then
    chmod 0600 $private_key_path

    eval $(ssh-agent) >/dev/null 2>&1
    trap "kill $SSH_AGENT_PID" 0

    SSH_ASKPASS=$ASSETS/helpers/askpass.sh DISPLAY= ssh-add $private_key_path >/dev/null

    mkdir -p ~/.ssh
    cat > ~/.ssh/config <<EOF
StrictHostKeyChecking no
LogLevel quiet
EOF
    chmod 0600 ~/.ssh/config
  fi
}

configure_git_global() {
  local git_config_payload="$1"
  eval $(echo "$git_config_payload" | \
    jq -r ".[] | \"git config --global '\\(.name)' '\\(.value)'; \"")
}

configure_git_ssl_verification() {
  if [ "$1" = "true" ]; then
    export GIT_SSL_NO_VERIFY=true
  fi
}

add_pullrequest_metadata_basic() {
  # $1: pull request number
  # $2: pull request repository
  # $3: skip ssl verification
  local repo_name=$(basename "$2" | sed "s/.git$//")
  local repo_project=$(basename $(dirname "$2"))

  # parse uri and retrieve host
  uri_parser "$2"
  local repo_host="${uri_schema}://${uri_address}"$(getBasePathOfBitbucket)

  local title=$(set -o pipefail; bitbucket_pullrequest "$repo_host" "$repo_project" "$repo_name" "$1" "" "$3" | jq -r '.title')
  local commit=$(git rev-parse HEAD)
  local author=$(git log -1 --format=format:%an)

  jq \
    --arg id "$1" \
    --arg title "$title" \
    --arg author "$author" \
    --arg commit "$commit" \
    --arg repository "$2" \
    '. + [
      {name: "id", value: $id},
      {name: "title", value: $title},
      {name: "author", value: $author},
      {name: "commit (merged source in target)", value: $commit},
      {name: "repository", value: $repository}
    ]'
}

add_pullrequest_metadata_commit() {
  # $1: key for adding to metadata
  # $2: commit filter for git log
  local filter="$2 -1"

  local commit=$(git log $filter --format=format:%H)
  local author=$(git log $filter --format=format:%an)
  local author_date=$(git log $filter --format=format:%ai)
  local committer=$(git log $filter --format=format:%cn)
  local committer_date=$(git log $filter --format=format:%ci)
  local message=$(git log $filter --format=format:%B)

  local metadata="$(jq -n \
    --arg commit "$commit" \
    --arg author "$author" \
    --arg author_date "$author_date" \
    --arg message "$message" \
    '[
        {name: ($commit + " commit"), value: $commit },
        {name: ($commit + " author"), value: $author },
        {name: ($commit + " author_date"), value: $author_date, type: "time" },
        {name: ($commit + " message"), value: $message, type: "message" }
    ]'
  )"

  if [ "$author" != "$committer" ]; then
    metadata=$(jq --arg commit "$1" --arg value "${committer}" \
      '. + [{name: ($commit + " committer"), value: $value }]' <<< "$metadata")
  fi
  if [ "$author_date" != "$committer_date" ]; then
    metadata=$(jq --arg commit "$1" --arg value "${committer_date}" \
      '. + [{name: ($commit + " committer_date"), value: $value, type: "time" }]' <<< "$metadata")
  fi

  jq --argjson metadata "$metadata" '. + $metadata'
}

pullrequest_metadata() {
  # $1: pull request number
  # $2: pull request repository
  # $3: skip ssl verification
  # $4: source_commit
  # $5: target_commit

  local source_commit=$4
  local target_commit=$5

  jq -n "[]" | \
    add_pullrequest_metadata_basic "$1" "$2" "$3" | \
    add_pullrequest_metadata_commit "source" "$source_commit" | \
    add_pullrequest_metadata_commit "target" "$target_commit"
}

configure_credentials() {
  local username=$(jq -r '.source.username // ""' < $1)
  local password=$(jq -r '.source.password // ""' < $1)
  local token=$(jq -r '.source.token // ""' < $1)

  rm -f $HOME/.netrc
  if [ "$username" != "" -a "$password" != "" ]; then
    echo "default login $username password $password" > $HOME/.netrc
  fi

  if [ "$token" != "" ]; then
    git config --global --add http.extraHeader "Authorization: Bearer $token"
    TOKEN="-H \"Authorization: Bearer $token\""
  fi
}
