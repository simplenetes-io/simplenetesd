# The Simplenetes Daemon (simplenetesd)
A Daemon which runs on the hosts in the cluster to manage the life cycles of the pods.

## Build a release of the daemon
```sh
./make.sh
```

## Install
`simplenetesd` is a standalone executable, written in POSIX-compliant shell script and will run anywhere there is Bash/Dash/Ash installed.

```sh
LATEST_VERSION=$(curl -L -s https://github.com/simplenetes-io/simplenetesd/releases/latest)
LATEST_VERSION=$(echo $LATEST_VERSION | sed -e 's/.*tag_name\=\([^"]*\)\&.*/\1/')
wget https://github.com/simplenetes-io/simplenetesd/releases/download/$LATEST_VERSION/simplenetesd
chmod +x simplenetesd
sudo mv simplenetesd /usr/local/bin
```

For further instructions on the Daemon refer to the Simplenetes [documentation](https://github.com/simplenetes-io/simplenetes/blob/master/doc/INSTALLING.md).
