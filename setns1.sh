# ノードの作成
sudo ip netns add node1
sudo ip netns add node2

# 仮想ケーブル(vethペア)の作成と接続
sudo ip link add veth-node1 type veth peer name veth-node2
sudo ip link set veth-node1 netns node1
sudo ip link set veth-node2 netns node2

# IPアドレスの設定とリンクアップ
sudo ip netns exec node1 ip addr add 192.168.1.1/24 dev veth-node1
sudo ip netns exec node1 ip link set veth-node1 up
sudo ip netns exec node1 ip link set lo up

sudo ip netns exec node2 ip addr add 192.168.1.2/24 dev veth-node2
sudo ip netns exec node2 ip link set veth-node2 up
sudo ip netns exec node2 ip link set lo up
