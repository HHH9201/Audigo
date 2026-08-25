package main

import (
	"net/http"
	"strings"
)

// baseApi 后端服务的地址
var baseApi = "https://localhost:40000"

// 网关鉴权 token（部署时配置的 Authorization: Bearer）
const apiToken = "768b27f839b768c39fa3c23b9f6c5a8c620763bb322968a589ced243f7e1803b"

// roundTripFunc 包装 http.Transport，为发往 baseApi 的请求自动附加网关鉴权头
type roundTripFunc func(req *http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) {
	return f(req)
}

func init() {
	base := http.DefaultTransport.(*http.Transport).Clone()
	http.DefaultTransport = roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if strings.HasPrefix(req.URL.String(), baseApi) {
			req.Header.Set("Authorization", "Bearer "+apiToken)
		}
		return base.RoundTrip(req)
	})
}
