import { sleep, check } from 'k6';
import { getJar, loadHomepage, browseCategory, viewProduct } from './common.js';

export const options = {
  vus: __ENV.VUS || 10,
  duration: __ENV.DURATION || '2m',
};

export default function () {
  const jar = getJar();

  let res = loadHomepage(jar);
  check(res, { 'homepage': r => r.status === 200 });

  sleep(1);

  let category = Math.floor(Math.random() * 5) + 1;
  res = browseCategory(jar, category);
  check(res, { 'category': r => r.status === 200 });

  sleep(1);

  let product = Math.floor(Math.random() * 50) + 1;
  res = viewProduct(jar, product);
  check(res, { 'product': r => r.status === 200 });

  sleep(1);
}
