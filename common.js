import http from 'k6/http';

export const BASE_URL = 'http://localhost:8080';

export function getJar() {
  return http.cookieJar();
}

export function loadHomepage(jar) {
  return http.get(`${BASE_URL}/tools.descartes.teastore.webui/`, { jar });
}

export function browseCategory(jar, category) {
  return http.get(`${BASE_URL}/tools.descartes.teastore.webui/category?category=${category}`, { jar });
}

export function viewProduct(jar, product) {
  return http.get(`${BASE_URL}/tools.descartes.teastore.webui/product?id=${product}`, { jar });
}

export function addToCart(jar, product) {
  return http.post(`${BASE_URL}/tools.descartes.teastore.webui/cartAction`, {
    productid: product,
    action: 'add'
  }, { jar });
}
