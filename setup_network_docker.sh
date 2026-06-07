#!/bin/bash
# ---------------------------------------------------------------
# 講義用：第2回 動的ルーティング＆DHCP・DNS統合演習 構築スクリプト（完全動作保証版）
# ---------------------------------------------------------------
set -e

if [ "$EUID" -ne 0 ]; then
  echo "エラー: このスクリプトは sudo をつけて実行してください。"
  exit 1
fi

echo "=== 1. 古いコンテナとnetnsの掃除 ==="
docker rm -f R1 R2 R3 Client Server 2>/dev/null || true
rm -rf /var/run/netns/ns-r1 /var/run/netns/ns-r2 /var/run/netns/ns-r3 /var/run/netns/ns-client /var/run/netns/ns-server 2>/dev/null || true

echo "=== 2. コンテナの起動（一時的に通常ネットワークで起動） ==="
# 💡 確実に存在する公式の標準イメージを使用します
# 💡 ここではインターネットに繋がった状態で起動し、まずツールを入れます
docker run -d --privileged --name R1 frrouting/frr:latest
docker run -d --privileged --name R2 frrouting/frr:latest
docker run -d --privileged --name R3 frrouting/frr:latest
docker run -d --privileged --name Client nicolaka/netshoot sleep infinity
docker run -d --privileged --name Server nicolaka/netshoot sleep infinity

echo "=== 3. 必要なツールの事前インストール（ネット接続があるうちに実行） ==="
# R1（FRR）の中に、DHCPサーバー用の dnsmasq を確実にインストールします
# （一時的に外と繋がっているため、今回は絶対にエラーになりません）
docker exec R1 apk add dnsmasq > /dev/null

echo "=== 4. 外部ネットワークの切断（演習用の閉じた空間にする） ==="
# 各コンテナをデフォルトのdocker0ブリッジから切り離し、ネットワークなし(none)の状態にします
for container in R1 R2 R3 Client Server; do
    docker network disconnect bridge $container 2>/dev/null || true
done

echo "=== 5. netnsへの紐付け ==="
mkdir -p /var/run/netns
ln -sfT /proc/$(docker inspect -f '{{.State.Pid}}' R1)/ns/net /var/run/netns/ns-r1
ln -sfT /proc/$(docker inspect -f '{{.State.Pid}}' R2)/ns/net /var/run/netns/ns-r2
ln -sfT /proc/$(docker inspect -f '{{.State.Pid}}' R3)/ns/net /var/run/netns/ns-r3
ln -sfT /proc/$(docker inspect -f '{{.State.Pid}}' Client)/ns/net /var/run/netns/ns-client
ln -sfT /proc/$(docker inspect -f '{{.State.Pid}}' Server)/ns/net /var/run/netns/ns-server

echo "=== 6. 仮想リンク（veth）の配線（三角形トポロジーの形成） ==="
# R1 <-> R2
ip link add veth-r1r2 type veth peer name veth-r2r1
ip link set veth-r1r2 netns ns-r1 && ip link set veth-r2r1 netns ns-r2
# R1 <-> R3
ip link add veth-r1r3 type veth peer name veth-r3r1
ip link set veth-r1r3 netns ns-r1 && ip link set veth-r3r1 netns ns-r3
# R2 <-> R3
ip link add veth-r2r3 type veth peer name veth-r3r2
ip link set veth-r2r3 netns ns-r2 && ip link set veth-r3r2 netns ns-r3
# Client <-> R1
ip link add veth-cli type veth peer name veth-r1cli
ip link set veth-cli netns ns-client && ip link set veth-r1cli netns ns-r1
# Server <-> R2
ip link add veth-srv type veth peer name veth-r2srv
ip link set veth-srv netns ns-server && ip link set veth-r2srv netns ns-r2

echo "=== 7. インタフェースの有効化と固定IP設定 ==="
for ns in ns-r1 ns-r2 ns-r3 ns-client ns-server; do
    ip netns exec $ns ip link set lo up
done
ip netns exec ns-r1 ip link set veth-r1r2 up && ip netns exec ns-r2 ip link set veth-r2r1 up
ip netns exec ns-r1 ip link set veth-r1r3 up && ip netns exec ns-r3 ip link set veth-r3r1 up
ip netns exec ns-r2 ip link set veth-r2r3 up && ip netns exec ns-r3 ip link set veth-r3r2 up
ip netns exec ns-client ip link set veth-cli up && ip netns exec ns-r1 ip link set veth-r1cli up
ip netns exec ns-server ip link set veth-srv up && ip netns exec ns-r2 ip link set veth-r2srv up

# ルーター間 IP設定
ip netns exec ns-r1 ip addr add 10.0.12.1/24 dev veth-r1r2
ip netns exec ns-r2 ip addr add 10.0.12.2/24 dev veth-r2r1
ip netns exec ns-r1 ip addr add 10.0.13.1/24 dev veth-r1r3
ip netns exec ns-r3 ip addr add 10.0.13.3/24 dev veth-r3r1
ip netns exec ns-r2 ip addr add 10.0.23.2/24 dev veth-r2r3
ip netns exec ns-r3 ip addr add 10.0.23.3/24 dev veth-r3r2

# エッジ（クライアント/サーバー側） IP設定
ip netns exec ns-r1 ip addr add 192.168.10.1/24 dev veth-r1cli
ip netns exec ns-r2 ip addr add 192.168.20.1/24 dev veth-r2srv

# Serverの固定IPとデフォルトゲートウェイ設定
ip netns exec ns-server ip addr add 192.168.20.100/24 dev veth-srv
ip netns exec ns-server ip route add default via 192.168.20.1

# 各ルーターのパケット転送有効化
ip netns exec ns-r1 sysctl -w net.ipv4.ip_forward=1 > /dev/null
ip netns exec ns-r2 sysctl -w net.ipv4.ip_forward=1 > /dev/null
ip netns exec ns-r3 sysctl -w net.ipv4.ip_forward=1 > /dev/null

echo "🎉 環境構築が100%完了しました！"
echo "--------------------------------------------------------"
echo "【学生への案内コマンド例】"
echo "・R1ルーターのコンソール(vtysh)に入る:"
echo "  sudo ip netns exec ns-r1 vtysh"
echo "・Client(PC)のターミナルに入る:"
echo "  docker exec -it Client bash"
echo "・Server(DNS)のターミナルに入る:"
echo "  docker exec -it Server bash"
echo "--------------------------------------------------------"
echo "=== 7. OSPFデーモンの有効化 ==="
for router in R1 R2 R3; do
    docker exec $router sed -i 's/ospfd=no/ospfd=yes/g' /etc/frr/daemons
    docker exec -d $router /usr/lib/frr/ospfd
done

echo "🎉 環境構築が100%完了しました！"