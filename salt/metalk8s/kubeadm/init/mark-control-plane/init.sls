#
# State for kubeadm init mark-control-plane phase.
#
#
#
# Available states
# ================
#
# * configured    -> Applies label and taints to the node
#

include:
  - metalk8s.python-kubernetes
  - .configured
