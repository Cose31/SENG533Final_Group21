import { sleep, check } from 'k6';
import { getJar, loadHomepage, browseCategory, viewProduct, addToCart } from './common.js';

export const options = {
  vus: __ENV.VUS || 10,
  duration: __ENV.DURATION || '2m',
};

export default function () {
  const jar = getJar();

  let res = loadHomepage(jar);
  check(res, { 'homepage': r => r.status === 200 });

  let product = Math.floor(Math.random() * 50) + 1;
  res = viewProduct(jar, product);
  check(res, { 'product': r => r.status === 200 });

  sleep(1);

  res = addToCart(jar, product);
  check(res, { 'add to cart': r => r.status === 200 });

  sleep(1);

  // simulate repeated cart operations (stress persistence)
  for (let i = 0; i < 3; i++) {
    addToCart(jar, product);
  }

  sleep(1);
}
