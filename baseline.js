import http from 'k6/http';
import { sleep, check } from 'k6';

export const options = {
  vus: 10,              // baseline concurrency (adjust later)
  duration: '2m',       // steady-state window
  thresholds: {
    http_req_duration: ['p(95)<2000', 'p(99)<4000'], // sanity bounds
    http_req_failed: ['rate<0.01'],
  },
};

export const config = {
  http: {
    timeout: '10s',
  },
};

const BASE_URL = 'http://localhost:8080'; // change if needed

export default function () {
  // 1. Load homepage
  let res = http.get(`${BASE_URL}/tools.descartes.teastore.webui/`);
  check(res, { 'homepage loaded': (r) => r.status === 200 });

  sleep(1);

  // 2. Browse category (random-ish but deterministic range)
  let category = Math.floor(Math.random() * 5) + 1;
  res = http.get(`${BASE_URL}/tools.descartes.teastore.webui/category?category=${category}`);
  check(res, { 'category loaded': (r) => r.status === 200 });

  sleep(1);

  // 3. View product
  let product = Math.floor(Math.random() * 50) + 1;
  res = http.get(`${BASE_URL}/tools.descartes.teastore.webui/product?id=${product}`);
  check(res, { 'product loaded': (r) => r.status === 200 });

  sleep(1);

  // 4. (Optional baseline-light) Add to cart (low frequency)
  if (Math.random() < 0.2) {
    res = http.post(`${BASE_URL}/tools.descartes.teastore.webui/cartAction`, {
      productid: product,
      action: 'add'
    });
    check(res, { 'added to cart': (r) => r.status === 200 });
  }

  sleep(1);
}
