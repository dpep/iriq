module Iriq
  # Heuristic registrable-domain extractor. Strips subdomains so that
  # api.foo.com and app.foo.com both resolve to foo.com.
  #
  # Uses an inline allowlist of the ~50 most common multi-label public
  # suffixes (.co.uk, .com.au, .gov.uk, etc.) — covers the long tail of
  # real-world traffic without the ~3 MB cost of bundling the full Public
  # Suffix List. Niche multi-label TLDs (.priv.no, .tas.gov.au, etc.) will
  # be over-stripped; install the `public_suffix` gem and wire it in if
  # accuracy on those matters for your workload.
  module RegistrableDomain
    # rubocop:disable Layout/LineLength
    TWO_LABEL_SUFFIXES = %w[
      co.uk org.uk gov.uk ac.uk net.uk me.uk ltd.uk plc.uk sch.uk
      co.jp ac.jp or.jp ne.jp go.jp gr.jp ed.jp lg.jp
      com.au net.au org.au edu.au gov.au asn.au id.au
      co.nz net.nz org.nz govt.nz ac.nz school.nz
      com.br net.br org.br gov.br edu.br
      com.cn net.cn org.cn gov.cn edu.cn ac.cn
      co.za net.za org.za gov.za ac.za
      co.kr ne.kr or.kr re.kr go.kr ac.kr
      co.in net.in org.in gov.in ac.in
      co.il net.il org.il gov.il ac.il muni.il
      com.mx net.mx org.mx gob.mx edu.mx
      com.ar net.ar org.ar gov.ar
      com.hk net.hk org.hk gov.hk edu.hk
      com.tw net.tw org.tw gov.tw edu.tw
      com.sg net.sg org.sg gov.sg edu.sg per.sg
      com.tr net.tr org.tr gov.tr edu.tr k12.tr
    ].to_set.freeze
    # rubocop:enable Layout/LineLength

    IP_V4_RE = /\A\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\z/.freeze

    module_function

    # Given an authority (hostname, no port), return the registrable
    # domain. Returns the input unchanged for IP literals, single-label
    # hosts (`localhost`), and hosts that already match a 2-label apex.
    def for(host)
      return host if host.nil? || host.empty?
      return host if IP_V4_RE.match?(host)

      labels = host.split(".")
      return host if labels.size <= 2

      tail_two = labels.last(2).join(".")
      if TWO_LABEL_SUFFIXES.include?(tail_two)
        # Multi-label public suffix — keep last 3 labels (`foo.co.uk`).
        labels.last(3).join(".")
      else
        labels.last(2).join(".")
      end
    end
  end
end
