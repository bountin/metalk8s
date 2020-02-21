locals {
  nodes = {
    count   = var.nodes.count
    flavour = var.openstack_flavours[var.nodes.flavour]
    image   = var.openstack_images[var.nodes.image].image
    user    = var.openstack_images[var.nodes.image].user
  }
}

# Ports
resource "openstack_networking_port_v2" "public_nodes" {
  name       = "${local.prefix}-public-node-${count.index}"
  network_id = data.openstack_networking_network_v2.public_network.id

  admin_state_up = true

  security_group_ids = [
    openstack_networking_secgroup_v2.ingress.id,
    var.online
    ? openstack_networking_secgroup_v2.open_egress[0].id
    : openstack_networking_secgroup_v2.restricted_egress[0].id,
  ]

  count = local.nodes.count
}

resource "openstack_networking_port_v2" "control_plane_nodes" {
  name       = "${local.control_plane_network.name}-node-${count.index}"
  network_id = local.control_plane_subnet[0].network_id

  admin_state_up        = true
  no_security_groups    = true
  port_security_enabled = false

  fixed_ip {
    subnet_id = local.control_plane_subnet[0].id
  }

  count = local.control_plane_network.enabled ? local.nodes.count : 0
}

resource "openstack_networking_port_v2" "workload_plane_nodes" {
  name       = "${local.workload_plane_network.name}-node-${count.index}"
  network_id = local.workload_plane_subnet[0].network_id

  admin_state_up        = true
  no_security_groups    = true
  port_security_enabled = false

  fixed_ip {
    subnet_id = local.workload_plane_subnet[0].id
  }

  count = (
    local.workload_plane_network.enabled
    && ! local.workload_plane_network.reuse_cp
  ) ? local.nodes.count : 0
}

resource "openstack_compute_instance_v2" "nodes" {
  count = local.nodes.count

  depends_on = [
    openstack_networking_port_v2.public_nodes,
    openstack_networking_port_v2.control_plane_nodes,
    openstack_networking_port_v2.workload_plane_nodes,
  ]

  name        = "${local.prefix}-node-${count.index + 1}"
  image_name  = local.nodes.image
  flavor_name = local.nodes.flavour
  key_pair    = openstack_compute_keypair_v2.local.name

  # NOTE: this does not work - ifaces are not yet attached when this runs at
  #       first boot
  # user_data = <<-EOT
  # #cloud-config
  # network:
  #   version: 2
  #   ethernets:
  #     all:
  #       match:
  #         name: eth*
  #       dhcp4: true
  # EOT

  network {
    access_network = true
    port           = openstack_networking_port_v2.public_nodes[count.index].id
  }

  dynamic "network" {
    for_each = compact([
      length(openstack_networking_port_v2.control_plane_nodes) != 0
      ? openstack_networking_port_v2.control_plane_nodes[count.index].id : "",
      length(openstack_networking_port_v2.workload_plane_nodes) != 0
      ? openstack_networking_port_v2.workload_plane_nodes[count.index].id : "",
    ])
    iterator = port

    content {
      access_network = false
      port           = port.value
    }
  }

  connection {
    host        = self.access_ip_v4
    type        = "ssh"
    user        = local.nodes.user
    private_key = openstack_compute_keypair_v2.local.private_key
  }

  # Provision SSH identities
  provisioner "remote-exec" {
    inline = [
      "echo '${openstack_compute_keypair_v2.bastion.public_key}' >> ~/.ssh/authorized_keys",
      "echo '${openstack_compute_keypair_v2.bootstrap.public_key}' >> ~/.ssh/authorized_keys",
    ]
  }
}

locals {
  node_ips = [
    for node in openstack_compute_instance_v2.nodes : node.access_ip_v4
  ]
}


# Scripts provisioning
resource "null_resource" "provision_scripts_nodes" {
  count = local.nodes.count

  depends_on = [
    openstack_compute_instance_v2.nodes,
  ]

  triggers = {
    nodes = join(",", openstack_compute_instance_v2.nodes[*].id),
    script_hashes = join(",", compact([
      # List of hashes for scripts that will be used
      local.using_rhel.nodes ? local.script_hashes.rhsm_register : "",
      local.script_hashes.iface_config,
      local.bastion.enabled ? local.script_hashes.set_yum_proxy : "",
    ])),
  }

  connection {
    host        = openstack_compute_instance_v2.nodes[count.index].access_ip_v4
    type        = "ssh"
    user        = local.nodes.user
    private_key = openstack_compute_keypair_v2.local.private_key
  }

  # Provision scripts for remote-execution
  provisioner "remote-exec" {
    inline = ["mkdir -p /tmp/metalk8s"]
  }

  provisioner "file" {
    source      = "${path.root}/scripts"
    destination = "/tmp/metalk8s/"
  }

  provisioner "remote-exec" {
    inline = ["chmod -R +x /tmp/metalk8s/scripts"]
  }
}


resource "null_resource" "configure_rhsm_nodes" {
  # Configure RedHat Subscription Manager if enabled
  count = local.using_rhel.nodes ? local.nodes.count : 0

  depends_on = [
    openstack_compute_instance_v2.nodes,
    null_resource.provision_scripts_nodes,
  ]

  connection {
    host        = openstack_compute_instance_v2.nodes[count.index].access_ip_v4
    type        = "ssh"
    user        = local.nodes.user
    private_key = openstack_compute_keypair_v2.local.private_key
  }

  provisioner "remote-exec" {
    inline = [
      join(" ", [
        "sudo bash /tmp/metalk8s/scripts/rhsm-register.sh",
        "'${var.rhsm_username}' '${var.rhsm_password}'",
      ]),
    ]
  }

  provisioner "remote-exec" {
    when       = destroy
    on_failure = continue
    inline     = ["sudo subscription-manager unregister"]
  }
}


# TODO: use cloud-init
resource "null_resource" "nodes_iface_config" {
  count = local.nodes.count

  depends_on = [
    openstack_compute_instance_v2.nodes,
    null_resource.provision_scripts_nodes,
  ]

  triggers = {
    node = openstack_compute_instance_v2.nodes[count.index].id,
    cp_port = (
      length(openstack_networking_port_v2.control_plane_nodes) != 0
      ? openstack_networking_port_v2.control_plane_nodes[count.index].id
      : ""
    ),
    wp_port = (
      length(openstack_networking_port_v2.workload_plane_nodes) != 0
      ? openstack_networking_port_v2.workload_plane_nodes[count.index].id
      : ""
    )
  }

  connection {
    host        = openstack_compute_instance_v2.nodes[count.index].access_ip_v4
    type        = "ssh"
    user        = local.nodes.user
    private_key = openstack_compute_keypair_v2.local.private_key
  }

  # Configure network interfaces for private networks
  provisioner "remote-exec" {
    inline = [
      for mac_address in concat(
        length(openstack_networking_port_v2.control_plane_nodes) != 0
        ? [openstack_networking_port_v2.control_plane_nodes[count.index].mac_address]
        : [],
        length(openstack_networking_port_v2.workload_plane_nodes) != 0
        ? [openstack_networking_port_v2.workload_plane_nodes[count.index].mac_address]
        : [],
      ) :
      "sudo bash /tmp/metalk8s/scripts/network-iface-config.sh ${mac_address}"
    ]
  }
}

resource "null_resource" "nodes_use_proxy" {
  count = local.bastion.enabled && !var.online ? local.nodes.count : 0

  triggers = {
    bootstrap = openstack_compute_instance_v2.bootstrap.id,
    nodes     = join(",", openstack_compute_instance_v2.nodes[*].id),
  }

  depends_on = [
    openstack_compute_instance_v2.nodes,
    null_resource.bastion_http_proxy,
    null_resource.provision_scripts_nodes,
  ]

  connection {
    host        = openstack_compute_instance_v2.nodes[count.index].access_ip_v4
    type        = "ssh"
    user        = local.nodes.user
    private_key = openstack_compute_keypair_v2.local.private_key
  }

  provisioner "remote-exec" {
    inline = [
      join(" ", [
        "sudo python /tmp/metalk8s/scripts/set_yum_proxy.py",
        "http://${local.bastion_ip}:${local.bastion.proxy_port}",
      ]),
    ]
  }
}
