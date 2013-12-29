import cPickle
import zlib

def decode(data):
  return cPickle.loads(zlib.decompress(data))
