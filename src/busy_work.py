"""A little Spark work so the run uses some compute, then an optional sleep (argv[1], seconds). Writes nothing."""
import sys
import time

from pyspark.sql import SparkSession, functions as F

spark = SparkSession.builder.getOrCreate()
start = time.time()
n = spark.range(0, 200_000_000).select((F.col("id") % 1000).alias("k")).groupBy("k").count().count()
print(f"{n} groups in {time.time() - start:.1f}s as {spark.sql('select current_user()').first()[0]}")

sleep_seconds = int(sys.argv[1]) if len(sys.argv) > 1 else 0
if sleep_seconds:
    print(f"sleeping {sleep_seconds}s")
    time.sleep(sleep_seconds)
