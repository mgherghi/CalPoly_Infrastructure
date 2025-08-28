ovs-vsctl add-br mlnx_sriov
ovs-vsctl add-port mlnx_sriov mlnx-vf_bond trunks=[10,20,30,40,50,60,70,80,90,100]
for i in $(seq 0 9); do
    ovs-vsctl add-port mlnx_sriov enp65s0f0r"$i" tag=$((i+1))0
done
