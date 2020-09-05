package main

import (
	qemu "quycao/docker-machine-driver-qemu"

	"github.com/docker/machine/libmachine/drivers/plugin"
)

func main() {
	plugin.RegisterDriver(new(qemu.Driver))
}
