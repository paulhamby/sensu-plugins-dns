#! /usr/bin/env ruby
#
#   check-dyn-qps
#
# DESCRIPTION:
#   Hits the Dyn API to check the number of Queries Per Second and alerts
#   if you exceed your commited rate.
#   This is designed to be scheduled once per day, week and/or month
#
# OUTPUT:
#   plain text
#
# PLATFORMS:
#   Linux
#
# DEPENDENCIES:
#   gem: sensu-plugin
#
# USAGE:
#   #YELLOW
#
# NOTES:
#
# LICENSE:
# phamby@gmail.com
#   Released under the same terms as Sensu (the MIT license); see LICENSE
#   for details.

require 'sensu-plugin/check/cli'
require 'net/https'
require 'uri'
require 'json'
require 'csv'

#
# Check Dyn QPS - see description above
#
class CheckDynQPS < Sensu::Plugin::Check::CLI
	option :url,
		short: '-u URL',
		long: '--url URL',
		description: 'Dyn API URL',
		default: 'https://api2.dynect.net/REST/'

	option :customer,
		short: '-C',
		long: '--customer CUSTOMER',
		description: 'Your Dyn Customer Name',
		required: true

	option :user,
		short: '-U',
		long: '--username USER',
		description: 'Your Dyn Username',
		required: true

	option :password,
		short: '-P',
		long: '--password PASS',
		description: 'Your Dyn Password',
		required: true

	option :period,
		short: '-p',
		long: '--period day|week',
		description: 'Period of time to query. Options are: day, week, month',
		required: true

	option :critical,
		short: '-c',
		long: '--critical 20',
		description: 'Critical threshold. This could be your query allotment from Dyn',
		required: true

	option :warning,
		short: '-w',
		long: '--warning 15',
		description: 'Warning threshold. This could be close to your query allotment from Dyn',
		required: true

	option :retries,
		short: '-r',
		long: '--retries 100',
		description: 'The number of times we will retry the request when we receive a 301,302 or 307. You want this to be pretty high',
		default: 50



	def run
		if config[:period] == "day"
			start_ts = (Time.now - 86400).to_i
		elsif config[:period] == "week"
			start_ts = (Time.now - 604800).to_i
		elsif config[:period] == "month"
			start_ts = (Time.now - 2592000).to_i
		else
			unknown "Valid options for period are day, week or month"
		end
		end_ts = (Time.now).to_i

		url = URI.encode(config[:url])

		auth_token = login(url)

		qpsreport_url = URI.parse(url) + "QPSReport/"
		headers = { "Content-Type" => 'application/json', 'Auth-Token' => auth_token }
		http = Net::HTTP.new(qpsreport_url.host, qpsreport_url.port)
		http.use_ssl = true
		parameters = { :start_ts => start_ts, :end_ts => end_ts }
		response = http.post(qpsreport_url.path, parameters.to_json, headers)
		$try = 0
		$retries = config[:retries]
		begin
			if response.code == "200"
				break
			elsif ["301", "302", "307"].include? response.code
				redirected_url = response["location"]
				puts("Redirected to #{redirected_url}")
				puts("Retrying the request. This is try #{$try} of #{$retries}")
				response = http.get(redirected_url, headers)	
				$try +=1
				sleep 5
			else
				critical "Could not complete request after #{$try} retries\n"
			end
		end while $try < $retries

		result = JSON.parse(response.body)
		csv = result['data']['csv']

		values = []
		CSV.parse(csv) do |row|
			q=row[1]
			q=q.to_i
			if q.is_a?(Integer)
				#The data is in 300 second increments. Divide by 300 to get the amount of queries per second.
				q=(q/300)
				values.push(q)
			end
		end

		values.shift
		p = 0.95
		percent = percentile(values,p)
		puts percent

		if percent >= config[:critical].to_i
			percent = percent.to_s
			critical "DynQPS is critical. QPS is #{percent} of #{config[:critical]}"
		elsif percent >= config[:warning].to_i
			percent = percent.to_s
			warning "DynQPS is warning #{percent} of #{config[:warning]}"
		else
			percent = percent.to_s
			ok "DynQPS is ok #{percent} of #{config[:warning]}"
		end

		logout

	rescue SocketError, Timeout::Error, Errno::EINVAL, Errno::ECONNRESET, EOFError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError => e
		critical "#{config[:url]} is not responding. #{e}"
	end

	def login(url)
		login_url = URI.parse(url) + "Session/"
		headers = { "Content-Type" => 'application/json' }
		http = Net::HTTP.new(login_url.host, login_url.port)
		http.use_ssl = true

		session_data = { :customer_name => config[:customer], :user_name => config[:user], :password => config[:password] }
		response = http.post(login_url.path, session_data.to_json, headers)

		result = JSON.parse(response.body)
		auth_token = result['data']['token']
		return auth_token

	rescue SocketError, Timeout::Error, Errno::EINVAL, Errno::ECONNRESET, EOFError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError => e
		critical "#{config[:url]} is not responding. #{e}"
	end

	def logout
		http.delete(login_url.path, headers)
	rescue SocketError, Timeout::Error, Errno::EINVAL, Errno::ECONNRESET, EOFError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError => e
		critical "#{config[:url]} is not responding. #{e}"
	end

	#borrowed from http://stackoverflow.com/a/11785414, thanks justin-ko!
	def percentile(values, percentile)
		values_sorted = values.sort
		k = (percentile*(values_sorted.length-1)+1).floor - 1
		f = (percentile*(values_sorted.length-1)+1).modulo(1)

		return values_sorted[k] + (f * (values_sorted[k+1] - values_sorted[k]))
	end
end
