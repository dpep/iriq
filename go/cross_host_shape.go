package iriq

import "sort"

// CrossHostShape is a route shape that recurs across multiple hosts.
//
// Emitted by Corpus.CrossHostShapes. The shape string ("/users/{user_id}")
// is the cluster's rendered placeholder form; two clusters with the same
// shape but different hosts coalesce into one record.
//
// A shape appearing at N hosts is strong evidence of a semantic pattern
// rather than a host-local quirk — independent hosts are unlikely to
// invent the same `/users/{integer}` structure by accident. Future work
// can feed this signal into proposal confidence and corpus-informed
// normalization.
type CrossHostShape struct {
	Shape            string
	Hosts            []string // sorted lexicographically
	ObservationCount int
}

// HostCount returns the distinct host count for this shape.
func (c CrossHostShape) HostCount() int { return len(c.Hosts) }

// CrossHostShapes returns route shapes that recur across `minHosts` or
// more distinct hosts. Sorted by host count desc, then observation
// count desc, then shape asc (stable, deterministic).
func (cp *Corpus) CrossHostShapes(minHosts int) []CrossHostShape {
	if minHosts <= 0 {
		minHosts = 2
	}

	type agg struct {
		hosts map[string]struct{}
		count int
	}
	byShape := map[string]*agg{}

	for _, cl := range cp.storage.Clusters() {
		// Skip non-URL clusters (URN clusters have no host).
		if cl.Host == "" {
			continue
		}
		a, ok := byShape[cl.Shape]
		if !ok {
			a = &agg{hosts: map[string]struct{}{}}
			byShape[cl.Shape] = a
		}
		a.hosts[cl.Host] = struct{}{}
		a.count += cl.Count
	}

	var out []CrossHostShape
	for shape, a := range byShape {
		if len(a.hosts) < minHosts {
			continue
		}
		hosts := make([]string, 0, len(a.hosts))
		for h := range a.hosts {
			hosts = append(hosts, h)
		}
		sort.Strings(hosts)
		out = append(out, CrossHostShape{
			Shape:            shape,
			Hosts:            hosts,
			ObservationCount: a.count,
		})
	}

	sort.Slice(out, func(i, j int) bool {
		if out[i].HostCount() != out[j].HostCount() {
			return out[i].HostCount() > out[j].HostCount()
		}
		if out[i].ObservationCount != out[j].ObservationCount {
			return out[i].ObservationCount > out[j].ObservationCount
		}
		return out[i].Shape < out[j].Shape
	})
	return out
}
