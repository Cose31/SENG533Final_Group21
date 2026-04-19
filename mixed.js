import { sleep, check} from 'k6';
import { getJar, loadHomepage, browseCategory, viewProduct, addToCart } from './common.js';

export const options = {
  vus: __ENV.VUS || 10,
  duration: __ENV.DURATION || '2m',
};

export default function () {
  const jar = getJar();
  const r = Math.random();

  let res = loadHomepage(jar);
  check(res, { 'homepage': r => r.status === 200 });
  
  let product = Math.floor(Math.random() * 50) + 1;

  if (r < 0.7) {
    // BROWSE
    let category = Math.floor(Math.random() * 5) + 1;
    res = browseCategory(jar, category);
    check(res, { 'category': r => r.status === 200 });

    sleep(1);
	  
    res = viewProduct(jar, product);
    check(res, { 'product': r => r.status === 200 });
  

  } else if (r < 0.9) {
    // CART
    res = viewProduct(jar, product);
    check(res, { 'product': r => r.status === 200 });

    sleep(1);
    addToCart(jar, product);

  } else {
    // CHECKOUT (simulated)
    res = viewProduct(jar, product);
    check(res, { 'product': r => r.status === 200 });

    addToCart(jar, product);
    sleep(1);
    addToCart(jar, product); // simulate purchase pressure
  }

  sleep(1);
}
