package bancatlan.hn;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;

/**
 * Endpoint REST del POC.
 *
 * En AWS Lambda estos metodos no cambian: la extension
 * quarkus-amazon-lambda-http traduce el evento de API Gateway
 * (payload format 2.0) a una peticion HTTP interna y enruta a JAX-RS.
 */
@Path("/hello")
public class GreetingResource {

    @GET
    @Produces(MediaType.TEXT_PLAIN)
    public String hello() {
        return "Hello World";
    }

    @GET
    @Path("/{name}")
    @Produces(MediaType.TEXT_PLAIN)
    public String helloName(@PathParam("name") String name) {
        return "Hello " + name;
    }
}
