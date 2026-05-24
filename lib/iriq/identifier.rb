module Iriq
  # Parsed identifier. Stores the original input alongside the structured fields
  # extracted by the parser.
  #
  # For URN-style inputs (`urn:isbn:0451450523`) only `scheme` and `nss` (the
  # Namespace Specific String) are populated; host/path are nil.
  class Identifier
    attr_reader :original, :scheme, :host, :port, :path,
                :path_segments, :query, :query_params, :fragment,
                :nss, :kind

    def initialize(original:, scheme: nil, host: nil, port: nil, path: nil,
                   path_segments: [], query: nil, query_params: {},
                   fragment: nil, nss: nil, kind: :url)
      @original      = original
      @scheme        = scheme
      @host          = host
      @port          = port
      @path          = path
      @path_segments = path_segments
      @query         = query
      @query_params  = query_params
      @fragment      = fragment
      @nss           = nss
      @kind          = kind
    end

    def urn?
      kind == :urn
    end

    def url?
      kind == :url
    end

    # Rebuild a canonical IRI-like string from the parsed fields. Preserves
    # Unicode display form (no punycode / percent-encoding pass).
    def canonical
      if urn?
        "urn:#{nss}"
      else
        out = +""
        out << "#{scheme}://" if scheme
        out << host if host
        out << ":#{port}" if port
        has_query    = query && !query.empty?
        has_fragment = fragment && !fragment.empty?
        if path_segments.any?
          out << "/" + path_segments.join("/")
        elsif has_query || has_fragment
          # RFC 3986: an authority with query/fragment but no path needs the
          # implied "/" to be a valid URI.
          out << "/"
        end
        out << "?#{query}"    if has_query
        out << "##{fragment}" if has_fragment
        out
      end
    end

    alias to_s canonical

    def ==(other)
      other.is_a?(Identifier) && other.canonical == canonical
    end
    alias eql? ==

    def hash
      canonical.hash
    end
  end
end
