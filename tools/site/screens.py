# -*- coding: utf-8 -*-
"""Drawn app screens for the device mock in each hero.

Drawn in HTML rather than screenshotted so they stay sharp on every screen
and re-theme with the page. Every screen mirrors a real screen in lib/screens:

  restaurant  -> restaurant/table_management_screen.dart
  kirana      -> retail/barcode_billing_screen.dart + customer_khata_screen.dart
  supermarket -> counter billing across several tills, analytics by till
  pharmacy    -> barcode billing with the GST invoice it prints
  retail      -> barcode billing with the customer's khata

The figures are made-up sample data and look it (round names, small shops).
"""


def _bar(title, sub, badge):
    return ('<div class="app-bar"><div><b>' + title + '</b><small>' + sub + '</small></div>'
            '<span class="app-badge">' + badge + '</span></div>')


def _lines(rows):
    return ''.join('<div class="ln"><span>' + a + '<small>' + b + '</small></span><b>' + c + '</b></div>'
                   for a, b, c in rows)


def _total(label, amt, pay):
    return ('<div class="tot"><span>' + label + '</span><b>' + amt + '</b></div>'
            '<div class="pay"><span class="upi-qr"></span><span>' + pay + '</span></div>')


def restaurant():
    tables = [('T1', 'free', 'Free', ''), ('T2', 'busy', '₹860', '42 min'), ('T3', 'busy', '₹1,240', '18 min'),
              ('T4', 'sel', '₹2,115', '55 min'), ('T5', 'free', 'Free', ''), ('T6', 'bill', 'Bill', 'asked'),
              ('T7', 'busy', '₹540', '9 min'), ('T8', 'free', 'Res. 8pm', '')]
    grid = ''.join('<div class="tb ' + k + '"><b>' + n + '</b><span>' + v + '</span><small>' + t + '</small></div>'
                   for n, k, v, t in tables)
    return (_bar('Tables &amp; Floor', 'Ground floor · 8 tables', '● Live') +
            '<div class="split"><div class="tgrid">' + grid + '</div>'
            '<div class="side"><div class="side-h">T4 · Round 3</div>' +
            _lines([('Paneer Tikka', 'Starter', '₹320'), ('Butter Naan ×4', 'Main', '₹240'),
                    ('Dal Makhani', 'Main', '₹290')]) +
            '<div class="kot">KOT #47 sent to kitchen ✓</div>' +
            _total('Table total', '₹2,115', 'Settle by UPI') + '</div></div>')


def kirana():
    return (_bar('Barcode Billing', 'Counter 1 · Shift open 7:02', 'Offline ✓') +
            '<div class="split"><div class="main">'
            '<div class="scan"><span>▮▯▮▮▯▮</span> 8901063 <i></i></div>' +
            _lines([('Atta 5 kg', '1 × ₹265', '₹265'), ('Toor dal (loose)', '1.5 kg × ₹140', '₹210'),
                    ('Salt 1 kg', '2 × ₹28', '₹56'), ('Butter 500 g', '1 × ₹285', '₹285')]) +
            '</div><div class="side"><div class="side-h">Customer khata</div>'
            '<div class="khata"><b>Ramesh K.</b><small>Regular · since Mar</small>'
            '<div class="due">₹2,340 <span>due</span></div>'
            '<div class="mini">Paid ₹1,000 · last Tue</div></div>' +
            _total('Bill', '₹816', 'Add to khata or UPI') + '</div></div>')


def supermarket():
    tills = [('Till 1', '₹18,420', 84), ('Till 2', '₹15,960', 72), ('Till 3', '₹21,305', 96), ('Till 4', '₹9,880', 45)]
    tt = ''.join('<div class="till"><span>' + n + '</span><b>' + v + '</b><div class="bar"><i style="width:' +
                 str(p) + '%"></i></div></div>' for n, v, p in tills)
    depts = [('Staples', 38), ('Dairy', 22), ('Snacks', 17), ('Home care', 13), ('Fresh', 10)]
    dd = ''.join('<div class="dp"><span>' + n + '</span><div class="bar"><i style="width:' + str(p * 2.4) +
                 '%"></i></div><b>' + str(p) + '%</b></div>' for n, p in depts)
    return (_bar('Analytics &amp; Rush', 'Today · 4 tills', 'Cloud ✓') +
            '<div class="tills">' + tt + '</div>'
            '<div class="split"><div class="main"><div class="side-h">By department</div>' + dd + '</div>'
            '<div class="side"><div class="side-h">Rush hours</div><div class="heat">' +
            ''.join('<i style="--h:' + str(h) + '"></i>' for h in (2, 3, 5, 4, 6, 8, 9, 7, 5, 6, 9, 10, 8, 4)) +
            '</div><div class="tot"><span>Day so far</span><b>₹65,565</b></div>'
            '<div class="mini">1,204 bills · avg ₹54</div></div></div>')


def pharmacy():
    return (_bar('Billing', 'Window 1 · INV-00412', 'GST ✓') +
            '<div class="split"><div class="main">'
            '<div class="scan"><span>🔍</span> para <i></i></div>' +
            _lines([('Paracetamol 650', 'HSN 3004 · 2 strips', '₹60'), ('Vitamin C chewable', 'HSN 2106 · 1', '₹95'),
                    ('ORS sachet', 'HSN 3004 · 5', '₹110'), ('Cough syrup 100 ml', 'HSN 3004 · 1', '₹120')]) +
            '</div><div class="side"><div class="side-h">Tax invoice</div>'
            '<div class="inv"><div><span>Taxable</span><b>₹343.75</b></div><div><span>CGST 6%</span><b>₹20.63</b></div>'
            '<div><span>SGST 6%</span><b>₹20.62</b></div></div>' +
            _total('Invoice', '₹385', 'UPI · Cash · Khata') + '</div></div>')


def retail():
    return (_bar('Barcode Billing', 'Counter · Sat rush', 'Offline ✓') +
            '<div class="split"><div class="main">'
            '<div class="scan"><span>▮▯▮▮▯▮</span> DJ-M-IND <i></i></div>' +
            _lines([('Denim jacket', 'M · Indigo', '₹1,899'), ('Cotton tee', 'L · White ×2', '₹998'),
                    ('Sneakers', 'UK 9 · Grey', '₹2,499'), ('Socks pack', 'Free size', '₹299')]) +
            '</div><div class="side"><div class="side-h">Customer</div>'
            '<div class="khata"><b>Priya S.</b><small>6 visits · last 12 Aug</small>'
            '<div class="due">₹0 <span>due</span></div><div class="mini">Part-paid ₹2,000 cleared</div></div>' +
            _total('Bill', '₹5,695', 'UPI QR on screen') + '</div></div>')


# The small phone beside the tablet: what the customer holds.
def phone(slug):
    if slug == 'restaurant':
        return ('<div class="ph-top"><b>Table 4</b><small>Menu</small></div>'
                '<div class="ph-dish"><span><b>Masala Dosa</b><small>₹140 · veg</small></span><i>+</i></div>'
                '<div class="ph-dish"><span><b>Filter Coffee</b><small>₹60 · veg</small></span><i>+</i></div>'
                '<div class="ph-dish"><span><b>Chicken 65</b><small>₹280</small></span><i>+</i></div>'
                '<div class="ph-cta"><span>2 items</span><b>Order ₹200</b></div>')
    amt = {'kirana': '₹816', 'supermarket': '₹1,248', 'pharmacy': '₹385', 'retail': '₹5,695'}.get(slug, '₹816')
    return ('<div class="ph-top"><b>Pay</b><small>UPI</small></div>'
            '<div class="ph-qr"><span class="upi-qr big"></span></div>'
            '<div class="ph-amt">' + amt + '</div><div class="ph-note">Straight to the shop\'s bank</div>'
            '<div class="ph-ok">✓ Paid</div>')


SCREENS = dict(restaurant=restaurant, kirana=kirana, supermarket=supermarket, pharmacy=pharmacy, retail=retail)
