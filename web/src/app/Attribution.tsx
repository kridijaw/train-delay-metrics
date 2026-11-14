export function Attribution({ allTrains }: { allTrains: boolean }) {
  return (
    <footer class="attribution">
      <p>
        <a href="https://huggingface.co/datasets/piebro/deutsche-bahn-data" rel="noopener">
          Data: piebro/deutsche-bahn-data (Deutsche Bahn), CC BY 4.0
        </a>
        {allTrains ? "." : ". Long-distance trains only."}
      </p>
    </footer>
  );
}
