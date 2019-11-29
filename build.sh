pushd /usr/share/logstash
/usr/share/logstash/bin/logstash-plugin remove logstash-input-sftp
popd
sudo -u logstash gem build logstash-input-sftp
sudo -u logstash gem install logstash-input-sftp-0.0.3.gem
pushd /usr/share/logstash 
/usr/share/logstash/bin/logstash-plugin install /usr/src/logstash-input-sftp/logstash-input-sftp-0.0.3.gem
popd
