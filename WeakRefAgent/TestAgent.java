public class TestAgent {
    public static void main(String[] args) throws Exception {
        System.out.println("Test program starting - will run for 40 seconds");
        
        // Allocate some memory to trigger GC
        for (int i = 0; i < 40; i++) {
            byte[] temp = new byte[10 * 1024 * 1024]; // 10MB
            temp[0] = (byte) i;
            Thread.sleep(1000);
            if (i % 10 == 0) {
                System.out.println("Iteration " + i + ", suggesting GC");
                System.gc();
            }
        }
        
        System.out.println("Test program done");
    }
}
