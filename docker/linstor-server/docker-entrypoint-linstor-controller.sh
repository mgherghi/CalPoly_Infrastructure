cat >/etc/linstor/linstor.toml<<EOF
[db]
connection_url = "jdbc:postgresql://linstor-nglab.j.aivencloud.com:14507/linstor?ssl=require&user=avnadmin&password=AVNS_5HQr2nhgJQbXhjGUXod"
EOF


/usr/share/linstor-server/bin/Controller --logs=/var/log/linstor-controller --config-directory=/etc/linstor
