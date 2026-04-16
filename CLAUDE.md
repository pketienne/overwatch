# Overwatch

Chef/Cinc cookbook for GPU-passthrough Windows gaming VM management on erasimus.

## Project layout

```
overwatch/master/
  attributes/      — VM configuration (VFIO, GPU, network)
  recipes/         — Chef recipe (single default recipe)
  resources/       — Custom Chef resource (overwatch.rb)
  templates/       — ERB templates (VM XML, systemd units, scripts)
  files/           — Static files deployed to host and guest
  compliance/      — InSpec compliance profile
  reference.md     — Detailed operational reference
```

## Canonical project metadata

Architecture (`skos:scopeNote`), description, utility deps, project
deps, and resources all live on `projects:01KKZGYKW5AJ9073RS8Y7VWWTS`
(label `Overwatch`) in the `projects#` graph — not in this file.
`SELECT ?p ?o WHERE { ?proj rdfs:label 'Overwatch' ; ?p ?o }` returns
the full picture; see also `projects:Resource` for `hasResource` usage.
