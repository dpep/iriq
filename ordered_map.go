package iriq

// OrderedMap is an insertion-ordered string->string map. We mirror Ruby's Hash
// ordering semantics for query parameters and other fields where users see the
// declared order (and where JSON round-trips need to be stable).
type OrderedMap struct {
	keys   []string
	values map[string]string
}

func NewOrderedMap() *OrderedMap {
	return &OrderedMap{values: map[string]string{}}
}

func (m *OrderedMap) Len() int {
	if m == nil {
		return 0
	}
	return len(m.keys)
}

func (m *OrderedMap) Set(k, v string) {
	if _, ok := m.values[k]; !ok {
		m.keys = append(m.keys, k)
	}
	m.values[k] = v
}

func (m *OrderedMap) Get(k string) (string, bool) {
	if m == nil {
		return "", false
	}
	v, ok := m.values[k]
	return v, ok
}

func (m *OrderedMap) Keys() []string {
	if m == nil {
		return nil
	}
	out := make([]string, len(m.keys))
	copy(out, m.keys)
	return out
}

// Each iterates in insertion order.
func (m *OrderedMap) Each(fn func(k, v string)) {
	if m == nil {
		return
	}
	for _, k := range m.keys {
		fn(k, m.values[k])
	}
}

func (m *OrderedMap) ToMap() map[string]string {
	if m == nil {
		return map[string]string{}
	}
	out := make(map[string]string, len(m.values))
	for k, v := range m.values {
		out[k] = v
	}
	return out
}
