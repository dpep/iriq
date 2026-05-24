module Iriq
  # Lightweight, Unicode-aware parser for URL/IRI/URN inputs.
  #
  # Intentionally NOT a full RFC 3986 / 3987 / WHATWG URL implementation. We
  # accept enough of the common shapes (URLs, scheme-less hosts, URNs, raw
  # Unicode hosts and paths) to support extraction, normalization, and clustering.
  module Parser
    SCHEME_RE = /\A([a-zA-Z][a-zA-Z0-9+\-.]*):/.freeze

    # Matches a host-ish first token before the first slash. We deliberately
    # allow any non-ASCII character so IRIs work without punycode.
    HOSTISH_RE = %r{
      \A
      (?<host>[^/?#\s:]+\.[^/?#\s:]+|localhost)  # something.something or localhost
      (?::(?<port>\d+))?
      (?<rest>[/?#].*)?
      \z
    }x.freeze

    DEFAULT_PORTS = {
      "http"  => 80,
      "https" => 443,
      "ftp"   => 21,
      "ws"    => 80,
      "wss"   => 443,
    }.freeze

    module_function

    def parse(input)
      raise ParseError, "input is nil" if input.nil?
      raise ParseError, "input must be a String" unless input.is_a?(String)

      stripped = input.strip
      raise ParseError, "input is empty" if stripped.empty?

      if (m = stripped.match(SCHEME_RE))
        scheme = m[1].downcase
        rest   = stripped[m[0].length..]

        if scheme == "urn"
          parse_urn(input, rest)
        elsif rest.start_with?("//")
          parse_authority_url(input, scheme, rest[2..])
        else
          # opaque scheme like mailto:foo@bar — keep nss, mark as urn-ish so we
          # don't pretend we know its host/path layout.
          Identifier.new(original: input, scheme: scheme, nss: rest, kind: :urn)
        end
      else
        # No scheme. If it looks like a hostname, assume https.
        if HOSTISH_RE.match?(stripped)
          parse_authority_url(input, "https", stripped)
        else
          raise ParseError, "cannot parse #{input.inspect}: no scheme and no host-like prefix"
        end
      end
    end

    def parse_urn(original, rest)
      raise ParseError, "urn missing namespace" if rest.nil? || rest.empty?

      Identifier.new(original: original, scheme: "urn", nss: rest, kind: :urn)
    end

    def parse_authority_url(original, scheme, remainder)
      m = remainder.match(HOSTISH_RE) || remainder.match(%r{\A(?<host>[^/?#]+?)(?::(?<port>\d+))?(?<rest>[/?#].*)?\z})
      raise ParseError, "cannot parse authority from #{original.inspect}" unless m

      host = m[:host].downcase
      port = m[:port]&.to_i
      port = nil if port && DEFAULT_PORTS[scheme] == port

      rest = m[:rest] || ""
      path, query, fragment = split_path_query_fragment(rest)
      segments = path_segments(path)

      Identifier.new(
        original:      original,
        scheme:        scheme,
        host:          host,
        port:          port,
        path:          "/" + segments.join("/"),
        path_segments: segments,
        query:         query,
        query_params:  parse_query(query),
        fragment:      fragment,
        kind:          :url,
      )
    end

    def split_path_query_fragment(rest)
      path     = rest
      query    = nil
      fragment = nil

      if (idx = path.index("#"))
        fragment = path[(idx + 1)..]
        path     = path[0...idx]
      end

      if (idx = path.index("?"))
        query = path[(idx + 1)..]
        path  = path[0...idx]
      end

      [path, query, fragment]
    end

    # Apply dot-segment normalization (RFC 3986 §5.2.4, lightweight version)
    # and drop empty segments from leading/trailing/duplicate slashes.
    def path_segments(path)
      return [] if path.nil? || path.empty? || path == "/"

      raw = path.sub(%r{\A/}, "").split("/")
      out = []
      raw.each do |seg|
        case seg
        when "", "."
          next
        when ".."
          out.pop
        else
          out << seg
        end
      end
      out
    end

    def parse_query(query)
      return {} if query.nil? || query.empty?

      query.split("&").each_with_object({}) do |pair, acc|
        k, v = pair.split("=", 2)
        next if k.nil? || k.empty?

        acc[k] = v
      end
    end
  end
end
