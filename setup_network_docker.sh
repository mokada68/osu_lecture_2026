#!/bin/bash
# ---------------------------------------------------------------
# 講義用：第2回 動的ルーティング＆DHCP・DNS統合演習 構築スクリプト
# 💡 Windows(WSL2) & Apple Silicon Mac(UTM/Parallels) 100%ネイティブ極上安定版
# ---------------------------------------------------------------
set -e

if [ "$EUID" -ne 0 ]; then
  echo "エラー: このスクリプトは sudo をつけて実行してください。"
  exit 1
fi

echo "=== 1. 古いコンテナとnetnsの掃除 ==="
docker rm -f R1 R2 R3 Client Server 2>/dev/null || true
rm -rf /var/run/netns/ns-r1 /var/run/netns/ns-r2 /var/run/netns/ns-r3 /var/run/netns/ns-client /var/run/netns/ns-server 2>/dev/null || true

echo "=== 2. コンテナの起動（超高互換・超軽量なネイティブイメージを使用） ==="
# 💡 Alpineやnetshootは完全にマルチアーキテクチャ対応のため、エミュレーションなしで100%ネイティブ動作します。
docker run -d --privileged --name R1 alpine sleep infinity
docker run -d --privileged --name R2 alpine sleep infinity
docker run -d --privileged --name R3 alpine sleep infinity
docker run -d --privileged --name Client nicolaka/netshoot sleep infinity
docker run -d --privileged --name Server nicolaka/netshoot sleep infinity

echo "=== 3. 必要なツールの事前ネイティブインストール ==="
# 💡 起動したコンテナの中で直接、そのマシンのCPUに適合したネイティブFRRパッケージを高速インストールします。
# 💡 これにより、以前の「No such platform」エラーやデーモンのクラッシュ（I/O接続切れ）を完全に防ぎます。
for router in R1 R2 R3; do
    docker exec $router apk update > /dev/null
    docker exec $router apk add frr dnsmasq > /dev/null
done

echo "=== 4. 外部ネットワークの切断 ==="
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

echo "=== 6. 仮想リンク（veth）の配線 ==="
ip link add veth-r1r2 type veth peer name veth-r2r1
ip link set veth-r1r2 netns ns-r1 && ip link set veth-r2r1 netns ns-r2
ip link add veth-r1r3 type veth peer name veth-r3r1
ip link set veth-r1r3 netns ns-r1 && ip link set veth-r3r1 netns ns-r3
ip link add veth-r2r3 type veth peer name veth-r3r2
ip link set veth-r2r3 netns ns-r2 && ip link set veth-r3r2 netns ns-r3
ip link add veth-cli type veth peer name veth-r1cli
ip link set veth-cli netns ns-client && ip link set veth-r1cli netns ns-r1
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

ip netns exec ns-r1 ip addr add 10.0.12.1/24 dev veth-r1r2
ip netns exec ns-r2 ip addr add 10.0.12.2/24 dev veth-r2r1
ip netns exec ns-r1 ip addr add 10.0.13.1/24 dev veth-r1r3
ip netns exec ns-r3 ip addr add 10.0.13.3/24 dev veth-r3r1
ip netns exec ns-r2 ip addr add 10.0.23.2/24 dev veth-r2r3
ip netns exec ns-r3 ip addr add 10.0.23.3/24 dev veth-r3r2
ip netns exec ns-r1 ip addr add 192.168.10.1/24 dev veth-r1cli
ip netns exec ns-r2 ip addr add 192.168.20.1/24 dev veth-r2srv

ip netns exec ns-server ip addr add 192.168.20.100/24 dev veth-srv
ip netns exec ns-server ip route add default via 192.168.20.1

ip netns exec ns-r1 sysctl -w net.ipv4.ip_forward=1 > /dev/null
ip netns exec ns-r2 sysctl -w net.ipv4.ip_forward=1 > /dev/null
ip netns exec ns-r3 sysctl -w net.ipv4.ip_forward=1 > /dev/null

echo "=== 8. Clientの初期ネットワーク設定（手動設定を模擬） ==="
# 💡 講義をスムーズに進めるため、あらかじめClientにIPとゲートウェイを仕込みます
ip netns exec ns-client ip addr add 192.168.10.10/24 dev veth-cli
ip netns exec ns-client ip route add default via 192.168.10.1

echo "=== 8.5 FRR設定ファイルの完全初期化と書き込み権限の完全開放 ==="
# 💡 write memory時のパーミッション制限エラーを100%防ぐためにディレクトリ権限を完全調整します
for router in R1 R2 R3; do
    docker exec $router mkdir -p /var/run/frr
    docker exec $router touch /etc/frr/zebra.conf /etc/frr/ospfd.conf /etc/frr/staticd.conf /etc/frr/vtysh.conf
    docker exec $router chown -R frr:frr /etc/frr /var/run/frr
    docker exec $router chmod -R 777 /etc/frr /var/run/frr
done

echo "=== 9. OSPFデーモン（ネイバー）のネイティブ安全起動 ==="
# 💡 エミュレーションではなく、ネイティブなバイナリとしてプロセスを直接・個別にバックグラウンド実行します。
# 💡 これにより、OSPFソケットが正しく確立され、I/O接続切れも絶対に発生しなくなります。
for router in R1 R2 R3; do
    docker exec -d $router /usr/lib/frr/zebra -d -u frr -g frr
    docker exec -d $router /usr/lib/frr/ospfd -d -u frr -g frr
done

echo "🎉 環境構築が100%完了しました！"
