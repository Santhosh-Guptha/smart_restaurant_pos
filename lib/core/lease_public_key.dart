/// Public half of the licence-lease signing key (RSA-2048, e = 65537).
///
/// The private half lives only in the Apps Script project as Script property
/// LEASE_SIGNING_KEY (PKCS#8 PEM). It was generated on the owner's machine
/// into secrets/lease_signing_key.pem, which git ignores. Rotating the key
/// means a new app build with the new modulus here.
const String kLeasePublicModulusHex =
    'f086b18af99885bf879e966377de0efabd5362ac46894706f6d32604d8b6e8fe'
    '26e0ebc1be02a5aa77ae627e18a80e1aa2235cdea82abf6d135229b05465408c'
    '0df03d79c52dd63a223f87d46d08afba8923173a764814df042ffde9f691d4d6'
    '48a1cfb6958765f2b72d56adcdf071772fc82c6a6d84ab36e456a7bf73fb7ed5'
    '9b4eb7c6d9d8dfac002b532aa20abae49e1f25fa29d6c12ee9a4ef3ffb6689a8'
    'b7e969114e45976c955595251351f0ab014403d5e59f96d3f732ef0c0dca5169'
    '96d727be433f916345aadb638e8767431a59263d67f157761318eb636ffed3ea'
    '986fed91d83ec2a2fb0b79a385143ab2a7fde3ba50bbc69bccdafcf609a27b6b';

const int kLeasePublicExponent = 65537;
