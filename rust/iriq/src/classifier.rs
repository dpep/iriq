// Heuristic classifier for individual path segments and query values.
// Mirrors Ruby's SegmentClassifier.

use crate::registrable_domain::IPV4_RE;
use once_cell::sync::Lazy;
use regex::Regex;
use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SegmentType {
    Literal,
    Integer,
    Float,
    /// Corpus-only umbrella when both Integer and Float coexist without
    /// either hitting a strong majority. Classifier never returns Number
    /// for an individual value.
    Number,
    Uuid,
    Date,
    Timestamp,
    Hash,
    Slug,
    Ipv4,
    Ipv6,
    Url,
    Email,
    Boolean,
    Version,
    Locale,
    Currency,
    Phone,
    Jwt,
    Mime,
    File,
    Color,
    Coordinate,
    Country,
    Base64,
    Year,
    HttpStatus,
    Enum,
    /// Corpus-only rung below Enum: a param that varies across free-form literal
    /// values but isn't a confident bounded set yet. Never returned for a
    /// single value.
    String,
    OpaqueId,
}

impl SegmentType {
    pub fn as_str(&self) -> &'static str {
        use SegmentType::*;
        match self {
            Literal => "literal",
            Integer => "integer",
            Float => "float",
            Number => "number",
            Uuid => "uuid",
            Date => "date",
            Timestamp => "timestamp",
            Hash => "hash",
            Slug => "slug",
            Ipv4 => "ipv4",
            Ipv6 => "ipv6",
            Url => "url",
            Email => "email",
            Boolean => "boolean",
            Version => "version",
            Locale => "locale",
            Currency => "currency",
            Phone => "phone",
            Jwt => "jwt",
            Mime => "mime",
            File => "file",
            Color => "color",
            Coordinate => "coordinate",
            Country => "country",
            Base64 => "base64",
            Year => "year",
            HttpStatus => "http_status",
            Enum => "enum",
            String => "string",
            OpaqueId => "opaque_id",
        }
    }
}

impl std::fmt::Display for SegmentType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

// ── Regex patterns ────────────────────────────────────────────────────────

static FLOAT_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^-?\d+\.\d+$").unwrap());
static ISO_TIME_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?(\.\d+)?(Z|[+\-]\d{2}:?\d{2})?$")
        .unwrap()
});
static HASH_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^[0-9a-fA-F]{32,}$").unwrap());
static SLUG_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^[a-z0-9]+(?:[-_][a-z0-9]+)+$").unwrap());
static LITERAL_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^\p{L}[\p{L}\p{M}_]*$").unwrap());
static OPAQUE_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^[A-Za-z0-9_\-.~]{4,}$").unwrap());
static IPV6_FULL_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{1,4}){7}$").unwrap());
static IPV6_COMPRESSED_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^[0-9a-fA-F:]{2,}$").unwrap());
static URL_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^[a-zA-Z][a-zA-Z0-9+.\-]*://\S+$").unwrap());
static SCHEMELESS_URL_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^[a-zA-Z0-9\-]+(?:\.[a-zA-Z0-9\-]+)*\.[a-zA-Z]{2,}/\S*$").unwrap());
static EMAIL_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(
        r"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)+$",
    )
    .unwrap()
});
static BOOLEAN_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^(?i:true|false)$").unwrap());
static VERSION_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^v\d+(?:\.\d+)*(?:[-+][A-Za-z0-9.\-]+)?$").unwrap());
static LOCALE_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^([a-z]{2,3})[-_]([A-Za-z0-9]{2,4})$").unwrap());
static LOCALE_BARE_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^[a-z]{2}$").unwrap());
static CURRENCY_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^[A-Za-z]{3}$").unwrap());
static PHONE_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^\+[ \-.()\d]{7,20}$").unwrap());
static PHONE_NANP_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^\(?([2-9]\d{2})\)?[ \-.]?([2-9]\d{2})[ \-.]?(\d{4})$").unwrap());
static FILE_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^[A-Za-z0-9][A-Za-z0-9_\-.~]*\.([A-Za-z0-9]{1,8})$").unwrap());
static COLOR_HEX_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$").unwrap()
});
static COORDINATE_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)$").unwrap());
static COUNTRY_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^[A-Z]{2}$").unwrap());
static BASE64_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^[A-Za-z0-9+/]{16,}={0,2}$").unwrap());
static JWT_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^ey[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+$").unwrap());
static MIME_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(
        r"^(?:text|image|video|audio|application|multipart|message|font|model)/[A-Za-z0-9!#$&^_+\-.]+$",
    )
    .unwrap()
});

static UUID_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
        .unwrap()
});
static INTEGER_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^\d+$").unwrap());
static COMPACT_DATE_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^\d{8}$").unwrap());
static DATE_ISO_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^\d{4}-\d{2}-\d{2}$").unwrap());
static DATE_SLASH_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^\d{4}/\d{2}/\d{2}$").unwrap());
static DATE_US_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^(\d{1,2})/(\d{1,2})/(\d{4})$").unwrap());
static FILE_EXT_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\.([A-Za-z0-9]{1,8})$").unwrap());

// ── Allowlists ────────────────────────────────────────────────────────────

static COUNTRY_CODES: Lazy<HashSet<&'static str>> = Lazy::new(|| {
    [
        "AD", "AE", "AF", "AG", "AL", "AM", "AO", "AR", "AT", "AU", "AZ", "BA", "BB", "BD", "BE",
        "BG", "BH", "BJ", "BM", "BN", "BO", "BR", "BS", "BT", "BW", "BY", "BZ", "CA", "CD", "CG",
        "CH", "CI", "CL", "CM", "CN", "CO", "CR", "CU", "CY", "CZ", "DE", "DJ", "DK", "DM", "DO",
        "DZ", "EC", "EE", "EG", "ER", "ES", "ET", "FI", "FJ", "FK", "FM", "FO", "FR", "GA", "GB",
        "GE", "GH", "GI", "GL", "GM", "GN", "GR", "GT", "GU", "GW", "GY", "HK", "HN", "HR", "HT",
        "HU", "ID", "IE", "IL", "IM", "IN", "IQ", "IR", "IS", "IT", "JM", "JO", "JP", "KE", "KG",
        "KH", "KM", "KN", "KP", "KR", "KW", "KY", "KZ", "LA", "LB", "LC", "LI", "LK", "LR", "LS",
        "LT", "LU", "LV", "LY", "MA", "MC", "MD", "ME", "MG", "MK", "ML", "MM", "MN", "MO", "MR",
        "MT", "MU", "MV", "MW", "MX", "MY", "MZ", "NA", "NE", "NG", "NI", "NL", "NO", "NP", "NR",
        "NU", "NZ", "OM", "PA", "PE", "PF", "PG", "PH", "PK", "PL", "PR", "PT", "PW", "PY", "QA",
        "RE", "RO", "RS", "RU", "RW", "SA", "SB", "SC", "SD", "SE", "SG", "SI", "SK", "SL", "SM",
        "SN", "SO", "SR", "SS", "ST", "SV", "SY", "SZ", "TD", "TG", "TH", "TJ", "TM", "TN", "TO",
        "TR", "TT", "TV", "TW", "TZ", "UA", "UG", "US", "UY", "UZ", "VA", "VC", "VE", "VG", "VI",
        "VN", "VU", "WS", "YE", "ZA", "ZM", "ZW",
    ]
    .iter()
    .copied()
    .collect()
});

static LOCALE_LANGUAGE_CODES: Lazy<HashSet<&'static str>> = Lazy::new(|| {
    [
        "ar", "bg", "bn", "ca", "cs", "da", "de", "el", "en", "es", "et", "fa", "fi", "fr", "gu",
        "he", "hi", "hr", "hu", "id", "it", "ja", "ka", "kk", "km", "kn", "ko", "lt", "lv", "mk",
        "ml", "mr", "ms", "my", "nb", "nl", "no", "pa", "pl", "pt", "ro", "ru", "sk", "sl", "sr",
        "sv", "sw", "ta", "te", "th", "tl", "tr", "uk", "ur", "vi", "zh",
    ]
    .iter()
    .copied()
    .collect()
});

static CURRENCY_CODES: Lazy<HashSet<&'static str>> = Lazy::new(|| {
    [
        "USD", "EUR", "GBP", "JPY", "CNY", "CHF", "CAD", "AUD", "NZD", "HKD", "SGD", "INR", "KRW",
        "MXN", "BRL", "ZAR", "SEK", "NOK", "DKK", "PLN", "CZK", "HUF", "RUB", "TRY", "ILS", "AED",
        "SAR", "THB", "IDR", "PHP", "VND", "TWD", "MYR", "NGN", "EGP",
    ]
    .iter()
    .copied()
    .collect()
});

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FileKind {
    Image,
    Document,
    Data,
    Text,
    Web,
    Audio,
    Video,
    Archive,
    Code,
}

impl FileKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            FileKind::Image => "image",
            FileKind::Document => "document",
            FileKind::Data => "data",
            FileKind::Text => "text",
            FileKind::Web => "web",
            FileKind::Audio => "audio",
            FileKind::Video => "video",
            FileKind::Archive => "archive",
            FileKind::Code => "code",
        }
    }
}

static FILE_EXTENSION_KIND: Lazy<HashMap<&'static str, FileKind>> = Lazy::new(|| {
    let mut m = HashMap::new();
    use FileKind::*;
    for e in [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff", "tif", "ico", "avif", "heic",
        "heif",
    ] {
        m.insert(e, Image);
    }
    for e in [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf", "epub",
    ] {
        m.insert(e, Document);
    }
    for e in [
        "csv", "tsv", "json", "xml", "yaml", "yml", "parquet", "sqlite", "db", "ndjson", "jsonl",
    ] {
        m.insert(e, Data);
    }
    for e in ["txt", "md", "log", "markdown", "rst"] {
        m.insert(e, Text);
    }
    for e in ["html", "htm", "css", "js", "mjs", "cjs", "ts", "jsx", "tsx"] {
        m.insert(e, Web);
    }
    for e in ["mp3", "wav", "ogg", "flac", "aac", "m4a", "opus"] {
        m.insert(e, Audio);
    }
    for e in ["mp4", "mov", "avi", "mkv", "webm", "flv", "wmv", "m4v"] {
        m.insert(e, Video);
    }
    for e in ["zip", "tar", "gz", "bz2", "7z", "rar", "xz", "tgz"] {
        m.insert(e, Archive);
    }
    for e in [
        "rb", "py", "go", "java", "c", "cc", "cpp", "h", "hpp", "sh", "swift", "kt", "rs",
    ] {
        m.insert(e, Code);
    }
    m
});

static PARAM_NAME_HINTS: Lazy<HashMap<&'static str, SegmentType>> = Lazy::new(|| {
    use SegmentType::*;
    let mut m = HashMap::new();
    for k in ["phone", "tel", "telephone", "mobile", "cell"] {
        m.insert(k, Phone);
    }
    for k in ["email", "e_mail", "mail"] {
        m.insert(k, Email);
    }
    for k in ["locale", "lang", "language"] {
        m.insert(k, Locale);
    }
    for k in ["currency", "cur", "curr"] {
        m.insert(k, Currency);
    }
    for k in [
        "url",
        "uri",
        "redirect",
        "redirect_url",
        "return_to",
        "return_url",
        "callback",
        "callback_url",
        "next_url",
    ] {
        m.insert(k, Url);
    }
    for k in ["jwt", "bearer", "auth_token"] {
        m.insert(k, Jwt);
    }
    for k in ["mime", "content_type", "media_type"] {
        m.insert(k, Mime);
    }
    for k in ["color", "colour", "bg", "background", "fg", "foreground"] {
        m.insert(k, Color);
    }
    for k in [
        "coords",
        "coordinates",
        "geo",
        "location",
        "position",
        "latlng",
        "latlon",
    ] {
        m.insert(k, Coordinate);
    }
    for k in ["country", "country_code", "nation"] {
        m.insert(k, Country);
    }
    m
});

fn is_overridable(t: SegmentType) -> bool {
    matches!(
        t,
        SegmentType::Literal | SegmentType::OpaqueId | SegmentType::Slug
    )
}

/// Return a hinted type for a param name when the value type is generic.
/// `None` when no hint applies.
pub fn param_name_hint(name: &str, current: SegmentType) -> Option<SegmentType> {
    if name.is_empty() || !is_overridable(current) {
        return None;
    }
    PARAM_NAME_HINTS.get(name.to_lowercase().as_str()).copied()
}

pub fn display_type(t: SegmentType) -> &'static str {
    match t {
        SegmentType::Ipv4 | SegmentType::Ipv6 => "ip",
        _ => t.as_str(),
    }
}

pub fn color_kind(value: &str) -> Option<&'static str> {
    if COLOR_HEX_RE.is_match(value) {
        Some("hex")
    } else {
        None
    }
}

pub fn file_kind(value: &str) -> Option<FileKind> {
    let caps = FILE_EXT_RE.captures(value)?;
    let ext = caps.get(1).unwrap().as_str().to_ascii_lowercase();
    FILE_EXTENSION_KIND.get(ext.as_str()).copied()
}

pub fn canonical_currency(value: &str) -> Option<String> {
    if value.is_empty() {
        return None;
    }
    let up = value.to_ascii_uppercase();
    if CURRENCY_CODES.contains(up.as_str()) {
        Some(up)
    } else {
        None
    }
}

/// ISO 8601 canonical (YYYY-MM-DD). Returns None when the value isn't a
/// recognized date form or the y/m/d fall outside plausible bounds.
pub fn canonical_date(value: &str) -> Option<String> {
    if let Some(c) = canonical_date_from_forms(value) {
        return Some(c);
    }
    if COMPACT_DATE_RE.is_match(value) {
        let (y, m, d) = (&value[0..4], &value[4..6], &value[6..8]);
        if plausible_date(y, m, d) {
            return Some(format!("{}-{}-{}", y, m, d));
        }
    }
    None
}

fn canonical_date_from_forms(value: &str) -> Option<String> {
    if DATE_ISO_RE.is_match(value) {
        let (y, m, d) = (&value[0..4], &value[5..7], &value[8..10]);
        if plausible_date(y, m, d) {
            return Some(value.to_string());
        }
        return None;
    }
    if DATE_SLASH_RE.is_match(value) {
        let (y, m, d) = (&value[0..4], &value[5..7], &value[8..10]);
        if plausible_date(y, m, d) {
            return Some(format!("{}-{}-{}", y, m, d));
        }
        return None;
    }
    if let Some(caps) = DATE_US_RE.captures(value) {
        let mon = pad2(caps.get(1).unwrap().as_str());
        let day = pad2(caps.get(2).unwrap().as_str());
        let year = caps.get(3).unwrap().as_str();
        if plausible_date(year, &mon, &day) {
            return Some(format!("{}-{}-{}", year, mon, day));
        }
    }
    None
}

fn pad2(s: &str) -> String {
    if s.len() == 1 {
        format!("0{}", s)
    } else {
        s.to_string()
    }
}

fn plausible_date(y: &str, m: &str, d: &str) -> bool {
    let yi: i32 = y.parse().unwrap_or(-1);
    let mi: i32 = m.parse().unwrap_or(-1);
    let di: i32 = d.parse().unwrap_or(-1);
    (1900..=2100).contains(&yi) && (1..=12).contains(&mi) && (1..=31).contains(&di)
}

// ── Recognizers (ensemble) ────────────────────────────────────────────────

// Specificity bands — higher wins. Ties go to earlier in the list.
const SPECIFICITY_SEMANTIC: f64 = 1.0;
const SPECIFICITY_STRUCTURED: f64 = 0.8;
const SPECIFICITY_BOUNDED: f64 = 0.7;
const SPECIFICITY_TYPED: f64 = 0.5;

#[derive(Debug, Clone)]
pub struct Verdict {
    pub ty: SegmentType,
    pub confidence: f64,
    pub specificity: f64,
}

pub trait Recognizer: Send + Sync {
    fn try_classify(&self, segment: &str) -> Option<Verdict>;
}

pub fn segment_type_from_str(s: &str) -> Option<SegmentType> {
    use SegmentType::*;
    Some(match s {
        "literal" => Literal,
        "integer" => Integer,
        "float" => Float,
        "number" => Number,
        "uuid" => Uuid,
        "date" => Date,
        "timestamp" => Timestamp,
        "hash" => Hash,
        "slug" => Slug,
        "ipv4" => Ipv4,
        "ipv6" => Ipv6,
        "url" => Url,
        "email" => Email,
        "boolean" => Boolean,
        "version" => Version,
        "locale" => Locale,
        "currency" => Currency,
        "phone" => Phone,
        "jwt" => Jwt,
        "mime" => Mime,
        "file" => File,
        "color" => Color,
        "coordinate" => Coordinate,
        "country" => Country,
        "base64" => Base64,
        "year" => Year,
        "http_status" => HttpStatus,
        "enum" => Enum,
        "string" => String,
        "opaque_id" => OpaqueId,
        _ => return None,
    })
}

fn ensemble(segment: &str, recognizers: &[std::sync::Arc<dyn Recognizer>]) -> Option<Verdict> {
    let mut best: Option<Verdict> = None;
    let mut best_score = -1.0;
    for r in recognizers {
        if let Some(v) = r.try_classify(segment) {
            let score = v.specificity * v.confidence;
            if score > best_score {
                best_score = score;
                best = Some(v);
            }
        }
    }
    best
}

// UUID recognizer
struct UuidRecognizer;
impl Recognizer for UuidRecognizer {
    fn try_classify(&self, segment: &str) -> Option<Verdict> {
        if segment.len() != 36 || !segment.contains('-') || !UUID_RE.is_match(segment) {
            return None;
        }
        Some(Verdict {
            ty: SegmentType::Uuid,
            confidence: 1.0,
            specificity: SPECIFICITY_SEMANTIC,
        })
    }
}

// Date recognizer (ISO, slash, US)
struct DateRecognizer;
impl Recognizer for DateRecognizer {
    fn try_classify(&self, segment: &str) -> Option<Verdict> {
        let has_dash = segment.contains('-');
        let has_slash = segment.contains('/');
        if !has_dash && !has_slash {
            return None;
        }
        if !DATE_ISO_RE.is_match(segment)
            && !DATE_SLASH_RE.is_match(segment)
            && !DATE_US_RE.is_match(segment)
        {
            return None;
        }
        Some(Verdict {
            ty: SegmentType::Date,
            confidence: 1.0,
            specificity: SPECIFICITY_STRUCTURED,
        })
    }
}

// Integer recognizer (incl. timestamp + compact date)
const TS_SECONDS_MIN: i64 = 1_000_000_000;
const TS_SECONDS_MAX: i64 = 9_999_999_999;
const TS_MILLIS_MIN: i64 = 1_000_000_000_000;
const TS_MILLIS_MAX: i64 = 9_999_999_999_999;

struct IntegerRecognizer;
impl Recognizer for IntegerRecognizer {
    fn try_classify(&self, segment: &str) -> Option<Verdict> {
        let c = segment.bytes().next()?;
        if !c.is_ascii_digit() {
            return None;
        }
        if !INTEGER_RE.is_match(segment) {
            return None;
        }
        if let Ok(n) = segment.parse::<i64>() {
            if (TS_MILLIS_MIN..=TS_MILLIS_MAX).contains(&n)
                || (TS_SECONDS_MIN..=TS_SECONDS_MAX).contains(&n)
            {
                return Some(Verdict {
                    ty: SegmentType::Timestamp,
                    confidence: 1.0,
                    specificity: SPECIFICITY_BOUNDED,
                });
            }
        }
        if COMPACT_DATE_RE.is_match(segment) {
            let y: i32 = segment[0..4].parse().unwrap_or(-1);
            let m: i32 = segment[4..6].parse().unwrap_or(-1);
            let d: i32 = segment[6..8].parse().unwrap_or(-1);
            if (1900..=2100).contains(&y) && (1..=12).contains(&m) && (1..=31).contains(&d) {
                return Some(Verdict {
                    ty: SegmentType::Date,
                    confidence: 1.0,
                    specificity: SPECIFICITY_STRUCTURED,
                });
            }
        }
        Some(Verdict {
            ty: SegmentType::Integer,
            confidence: 1.0,
            specificity: SPECIFICITY_TYPED,
        })
    }
}

// ── Classifier ────────────────────────────────────────────────────────────

const CACHE_MAX: usize = 10_000;

pub struct SegmentClassifier {
    state: Mutex<ClassifierState>,
}

struct ClassifierState {
    cache: HashMap<String, SegmentType>,
    recognizers: Vec<std::sync::Arc<dyn Recognizer>>,
}

impl SegmentClassifier {
    pub fn new() -> Self {
        let recognizers: Vec<std::sync::Arc<dyn Recognizer>> = vec![
            std::sync::Arc::new(UuidRecognizer),
            std::sync::Arc::new(DateRecognizer),
            std::sync::Arc::new(IntegerRecognizer),
        ];
        Self {
            state: Mutex::new(ClassifierState {
                cache: HashMap::new(),
                recognizers,
            }),
        }
    }

    pub fn classify(&self, segment: &str) -> SegmentType {
        if segment.is_empty() {
            return SegmentType::Literal;
        }
        {
            let mut st = self.state.lock().unwrap();
            if let Some(&v) = st.cache.get(segment) {
                return v;
            }
            if st.cache.len() >= CACHE_MAX {
                st.cache.clear();
            }
        }
        let recognizers = {
            let st = self.state.lock().unwrap();
            st.recognizers.clone()
        };
        let t = compute_classification(segment, &recognizers);
        let mut st = self.state.lock().unwrap();
        st.cache.insert(segment.to_string(), t);
        t
    }

    pub fn variable(&self, t: SegmentType) -> bool {
        t != SegmentType::Literal
    }

    pub fn register_recognizer(&self, r: std::sync::Arc<dyn Recognizer>) {
        let mut st = self.state.lock().unwrap();
        st.recognizers.push(r);
        st.cache.clear();
    }

    pub fn recognizer_count(&self) -> usize {
        self.state.lock().unwrap().recognizers.len()
    }
}

impl Default for SegmentClassifier {
    fn default() -> Self {
        Self::new()
    }
}

pub static DEFAULT_CLASSIFIER: Lazy<SegmentClassifier> = Lazy::new(SegmentClassifier::new);

fn compute_classification(
    segment: &str,
    recognizers: &[std::sync::Arc<dyn Recognizer>],
) -> SegmentType {
    let bytes = segment.as_bytes();
    let size = bytes.len();
    if size == 0 {
        return SegmentType::Literal;
    }
    let first = bytes[0];
    let digit0 = first.is_ascii_digit();
    let has_dash = bytes.contains(&b'-');
    let has_dot = bytes.contains(&b'.');
    let has_colon = bytes.contains(&b':');
    let has_slash = bytes.contains(&b'/');
    let has_at = bytes.contains(&b'@');
    let has_under = bytes.contains(&b'_');
    let has_sep = has_dash || has_under;
    let has_comma = bytes.contains(&b',');
    let has_eq = bytes.contains(&b'=');
    let has_plus = bytes.contains(&b'+');

    if let Some(v) = ensemble(segment, recognizers) {
        return v.ty;
    }

    // JWT: starts with "ey" + size > 4 + exactly 2 dots
    if size > 4
        && bytes[0] == b'e'
        && bytes[1] == b'y'
        && segment.matches('.').count() == 2
        && JWT_RE.is_match(segment)
    {
        return SegmentType::Jwt;
    }
    if first == b'#' && COLOR_HEX_RE.is_match(segment) {
        return SegmentType::Color;
    }
    if has_colon && segment.contains("://") && URL_RE.is_match(segment) {
        return SegmentType::Url;
    }
    if has_at && EMAIL_RE.is_match(segment) {
        return SegmentType::Email;
    }
    if has_slash && MIME_RE.is_match(segment) {
        return SegmentType::Mime;
    }
    if has_dot && has_slash && SCHEMELESS_URL_RE.is_match(segment) {
        return SegmentType::Url;
    }
    if digit0 && has_dot && IPV4_RE.is_match(segment) {
        return classify_ipv4(segment);
    }
    if has_colon && IPV6_FULL_RE.is_match(segment) {
        return SegmentType::Ipv6;
    }
    if has_colon && segment.contains("::") && IPV6_COMPRESSED_RE.is_match(segment) {
        return SegmentType::Ipv6;
    }
    if has_comma && COORDINATE_RE.is_match(segment) {
        return classify_coordinate(segment);
    }
    if size >= 32 && HASH_RE.is_match(segment) {
        return SegmentType::Hash;
    }
    if first == b'v' && VERSION_RE.is_match(segment) {
        return SegmentType::Version;
    }
    if (4..=5).contains(&size) && BOOLEAN_RE.is_match(segment) {
        return SegmentType::Boolean;
    }
    if has_sep && LOCALE_RE.is_match(segment) {
        return classify_locale_pair(segment);
    }
    if size == 2 && LOCALE_BARE_RE.is_match(segment) {
        return classify_locale_bare(segment);
    }
    if has_colon && ISO_TIME_RE.is_match(segment) {
        return SegmentType::Timestamp;
    }
    if first == b'+' && PHONE_RE.is_match(segment) {
        return classify_phone(segment);
    }
    if (has_dash || has_dot || first == b'(') && PHONE_NANP_RE.is_match(segment) {
        return SegmentType::Phone;
    }
    if has_dot && FLOAT_RE.is_match(segment) {
        return SegmentType::Float;
    }
    if size == 3 && CURRENCY_RE.is_match(segment) {
        return classify_currency(segment);
    }
    if size == 2 && COUNTRY_RE.is_match(segment) {
        return classify_country(segment);
    }
    if size >= 16 && (has_eq || has_plus || has_slash) && BASE64_RE.is_match(segment) {
        return SegmentType::Base64;
    }
    if has_dot && FILE_RE.is_match(segment) {
        return classify_file(segment);
    }
    if has_sep && SLUG_RE.is_match(segment) {
        return SegmentType::Slug;
    }
    if LITERAL_RE.is_match(segment) {
        return SegmentType::Literal;
    }
    if OPAQUE_RE.is_match(segment) {
        return SegmentType::OpaqueId;
    }
    SegmentType::Literal
}

fn classify_coordinate(segment: &str) -> SegmentType {
    let Some(caps) = COORDINATE_RE.captures(segment) else {
        return SegmentType::OpaqueId;
    };
    let a: f64 = caps.get(1).unwrap().as_str().parse().unwrap_or(f64::NAN);
    let b: f64 = caps.get(2).unwrap().as_str().parse().unwrap_or(f64::NAN);
    if a.is_nan() || b.is_nan() {
        return SegmentType::OpaqueId;
    }
    if ((-90.0..=90.0).contains(&a) && (-180.0..=180.0).contains(&b))
        || ((-180.0..=180.0).contains(&a) && (-90.0..=90.0).contains(&b))
    {
        SegmentType::Coordinate
    } else {
        SegmentType::OpaqueId
    }
}

fn classify_country(segment: &str) -> SegmentType {
    if COUNTRY_CODES.contains(segment) {
        SegmentType::Country
    } else {
        SegmentType::Literal
    }
}

fn classify_file(segment: &str) -> SegmentType {
    let Some(caps) = FILE_RE.captures(segment) else {
        return SegmentType::OpaqueId;
    };
    let ext = caps.get(1).unwrap().as_str().to_ascii_lowercase();
    if FILE_EXTENSION_KIND.contains_key(ext.as_str()) {
        return SegmentType::File;
    }
    if SLUG_RE.is_match(segment) {
        return SegmentType::Slug;
    }
    SegmentType::OpaqueId
}

fn classify_phone(segment: &str) -> SegmentType {
    let digits = segment.bytes().filter(|b| b.is_ascii_digit()).count();
    if (7..=15).contains(&digits) {
        SegmentType::Phone
    } else {
        SegmentType::OpaqueId
    }
}

fn classify_currency(segment: &str) -> SegmentType {
    let up = segment.to_ascii_uppercase();
    if CURRENCY_CODES.contains(up.as_str()) {
        return SegmentType::Currency;
    }
    if LITERAL_RE.is_match(segment) {
        SegmentType::Literal
    } else {
        SegmentType::OpaqueId
    }
}

fn classify_locale_bare(segment: &str) -> SegmentType {
    if LOCALE_LANGUAGE_CODES.contains(segment) {
        SegmentType::Locale
    } else {
        SegmentType::Literal
    }
}

fn classify_locale_pair(segment: &str) -> SegmentType {
    let Some(caps) = LOCALE_RE.captures(segment) else {
        return SegmentType::Literal;
    };
    if LOCALE_LANGUAGE_CODES.contains(caps.get(1).unwrap().as_str()) {
        return SegmentType::Locale;
    }
    if SLUG_RE.is_match(segment) {
        SegmentType::Slug
    } else {
        SegmentType::Literal
    }
}

fn classify_ipv4(segment: &str) -> SegmentType {
    for oct in segment.split('.') {
        match oct.parse::<u32>() {
            Ok(n) if n <= 255 => continue,
            _ => return SegmentType::OpaqueId,
        }
    }
    SegmentType::Ipv4
}
