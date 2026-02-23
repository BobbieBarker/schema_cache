# Changelog

## 0.1.1

- Write-through now detects collections vs singular values by inspecting the cached data type instead of requiring an `"all_"` key prefix. The `key` argument to `read/4` is now a plain domain name (e.g. `"users"`).

## 0.1.0

- Initial release
